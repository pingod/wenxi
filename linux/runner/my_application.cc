#include "my_application.h"

#include <gio/gio.h>
#include <string.h>
#include <unistd.h>

#include <flutter_linux/flutter_linux.h>
#ifdef GDK_WINDOWING_X11
#include <gdk/gdkx.h>
#endif

#include "flutter/generated_plugin_registrant.h"

struct _MyApplication {
  GtkApplication parent_instance;
  char** dart_entrypoint_arguments;
  FlMethodChannel* theme_channel;
  FlMethodChannel* native_channel;
  FlMethodChannel* external_channel;
  GtkCssProvider* theme_provider;
  // logind inhibitor fd for the transfer keep-alive, -1 when inactive.
  gint sleep_inhibitor;
  // Download/resolve links handed over on the command line, oldest first.
  GQueue* pending_opens;
  guint open_sequence;
  // TRUE once the primary instance has created its window; later command lines
  // arrive from `asterlink <url>` invocations and must only be queued.
  gboolean started;
  // Startup link kept until the first view exists; a second instance may hand
  // over a link before Flutter has registered its channel handler.
  gchar* queued_open;
};

G_DEFINE_TYPE(MyApplication, my_application, GTK_TYPE_APPLICATION)

// Called when first Flutter frame received.
static void first_frame_cb(MyApplication* self, FlView* view) {
  gtk_widget_show(gtk_widget_get_toplevel(GTK_WIDGET(view)));
}


// The header bar is drawn by GTK, so it follows the GTK theme rather than the
// Flutter UI. Distributions ship very different GTK themes (a light Material
// You GTK theme under a dark app looks like a stray white strip), so the bar is
// painted from the app's effective brightness. Buttons and symbolic icons are
// left to the theme except for their colour, which must contrast with the bar.
static const char* kThemeCssDark =
    "headerbar, headerbar:backdrop {"
    "  background-image: none;"
    "  background-color: #1b1b1f;"
    "  color: #e8e8ea;"
    "  box-shadow: none;"
    "  border-color: rgba(255, 255, 255, 0.08);"
    "}"
    "headerbar label, headerbar .title { color: #e8e8ea; }"
    "headerbar image { color: #e8e8ea; -gtk-icon-style: symbolic; }"
    "headerbar button image { color: #e8e8ea; }"
    "headerbar button:hover { background-color: rgba(255, 255, 255, 0.10); }";

static const char* kThemeCssLight =
    "headerbar, headerbar:backdrop {"
    "  background-image: none;"
    "  background-color: #f3f3f6;"
    "  color: #1a1a1c;"
    "  box-shadow: none;"
    "  border-color: rgba(0, 0, 0, 0.10);"
    "}"
    "headerbar label, headerbar .title { color: #1a1a1c; }"
    "headerbar image { color: #1a1a1c; -gtk-icon-style: symbolic; }"
    "headerbar button image { color: #1a1a1c; }"
    "headerbar button:hover { background-color: rgba(0, 0, 0, 0.08); }";

static void apply_header_bar_theme(MyApplication* self, gboolean dark) {
  if (self->theme_provider == nullptr) {
    self->theme_provider = gtk_css_provider_new();
    gtk_style_context_add_provider_for_screen(
        gdk_screen_get_default(), GTK_STYLE_PROVIDER(self->theme_provider),
        GTK_STYLE_PROVIDER_PRIORITY_APPLICATION);
  }
  GError* error = nullptr;
  gtk_css_provider_load_from_data(self->theme_provider,
                                  dark ? kThemeCssDark : kThemeCssLight, -1,
                                  &error);
  if (error != nullptr) {
    g_warning("Failed to apply the window theme: %s", error->message);
    g_clear_error(&error);
  }
}

// Dart sends the effective brightness after each theme change, matching the
// Windows `com.asterlink.app/window_theme` channel.
static void theme_method_call_cb(FlMethodChannel* channel,
                                 FlMethodCall* method_call, gpointer user_data) {
  MyApplication* self = MY_APPLICATION(user_data);
  g_autoptr(FlMethodResponse) response = nullptr;
  const gchar* name = fl_method_call_get_name(method_call);
  if (g_strcmp0(name, "setTheme") != 0) {
    response = FL_METHOD_RESPONSE(fl_method_not_implemented_response_new());
    fl_method_call_respond(method_call, response, nullptr);
    return;
  }

  FlValue* args = fl_method_call_get_args(method_call);
  gboolean dark = FALSE;
  if (args != nullptr && fl_value_get_type(args) == FL_VALUE_TYPE_MAP) {
    FlValue* value = fl_value_lookup_string(args, "dark");
    if (value != nullptr && fl_value_get_type(value) == FL_VALUE_TYPE_BOOL) {
      dark = fl_value_get_bool(value);
    }
  }
  apply_header_bar_theme(self, dark);
  response = FL_METHOD_RESPONSE(fl_method_success_response_new(nullptr));
  fl_method_call_respond(method_call, response, nullptr);
}

static void setup_theme_channel(MyApplication* self, FlView* view) {
  FlEngine* engine = fl_view_get_engine(view);
  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  self->theme_channel =
      fl_method_channel_new(fl_engine_get_binary_messenger(engine),
                            "com.asterlink.app/window_theme", FL_METHOD_CODEC(codec));
  fl_method_channel_set_method_call_handler(
      self->theme_channel, theme_method_call_cb, self, nullptr);
}

// Transfer keep-alive, matching the Windows `foreground` and macOS
// `preventSleep` behaviour: while a transfer is active the machine must not
// suspend. logind hands back a file descriptor that holds the inhibitor, so the
// fd has to stay open for the duration of the transfer.
static void release_sleep_inhibitor(MyApplication* self) {
  if (self->sleep_inhibitor >= 0) {
    close(self->sleep_inhibitor);
    self->sleep_inhibitor = -1;
  }
}

// `Inhibit` returns a pipe fd: "what" and "who" are written back on it, and
// closing the fd releases the inhibitor. A session without logind (or without
// permission) simply keeps no inhibitor; transfers still run, the machine may
// just suspend.
static gboolean hold_sleep_inhibitor(MyApplication* self) {
  if (self->sleep_inhibitor >= 0) return TRUE;
  GDBusConnection* connection = g_bus_get_sync(G_BUS_TYPE_SYSTEM, nullptr, nullptr);
  if (connection == nullptr) return FALSE;
  // The reply carries the fd out of band: `call_sync` with type "(h)" yields
  // only the handle *index* into a fd list that was never received. Asking for
  // the list explicitly is the only way to own a real descriptor, and holding
  // it is what keeps the inhibitor alive.
  GUnixFDList* fd_list = nullptr;
  GVariant* reply = g_dbus_connection_call_with_unix_fd_list_sync(
      connection, "org.freedesktop.login1", "/org/freedesktop/login1",
      "org.freedesktop.login1.Manager", "Inhibit",
      g_variant_new("(ssss)", "idle", "文析助手", "正在传输文件", "block"),
      G_VARIANT_TYPE("(h)"), G_DBUS_CALL_FLAGS_NONE, -1, nullptr, &fd_list,
      nullptr, nullptr);
  g_object_unref(connection);
  if (reply == nullptr) {
    if (fd_list != nullptr) g_object_unref(fd_list);
    return FALSE;
  }
  gint32 index = -1;
  g_variant_get(reply, "(h)", &index);
  g_variant_unref(reply);
  gint fd = fd_list != nullptr ? g_unix_fd_list_get(fd_list, index, nullptr) : -1;
  if (fd_list != nullptr) g_object_unref(fd_list);
  if (fd < 0) return FALSE;
  self->sleep_inhibitor = fd;
  return TRUE;
}

static void native_method_call_cb(FlMethodChannel* channel,
                                  FlMethodCall* method_call, gpointer user_data) {
  MyApplication* self = MY_APPLICATION(user_data);
  g_autoptr(FlMethodResponse) response = nullptr;
  const gchar* name = fl_method_call_get_name(method_call);
  if (g_strcmp0(name, "foreground") == 0) {
    FlValue* args = fl_method_call_get_args(method_call);
    gint64 active = -1;
    if (args != nullptr && fl_value_get_type(args) == FL_VALUE_TYPE_MAP) {
      FlValue* value = fl_value_lookup_string(args, "active");
      if (value != nullptr && fl_value_get_type(value) == FL_VALUE_TYPE_INT) {
        active = fl_value_get_int(value);
      }
    }
    if (active < 0 || active > 10000) {
      response = FL_METHOD_RESPONSE(fl_method_error_response_new(
          "arguments", "下载任务状态无效", nullptr));
    } else if (active == 0) {
      release_sleep_inhibitor(self);
      response = FL_METHOD_RESPONSE(fl_method_success_response_new(nullptr));
    } else if (hold_sleep_inhibitor(self)) {
      response = FL_METHOD_RESPONSE(fl_method_success_response_new(nullptr));
    } else {
      // Not fatal: the transfer keeps running, only the suspend block is gone.
      response = FL_METHOD_RESPONSE(fl_method_error_response_new(
          "foreground", "无法阻止系统休眠，传输仍会继续", nullptr));
    }
  } else if (g_strcmp0(name, "openExternalPlayer") == 0) {
    // Matches the macOS/Windows contract: launch the chosen player with the
    // media URL as its only argument, detached so this process never waits on
    // it. Only an absolute executable path and an http(s)/file URL are allowed.
    FlValue* args = fl_method_call_get_args(method_call);
    const gchar* application = nullptr;
    const gchar* url = nullptr;
    if (args != nullptr && fl_value_get_type(args) == FL_VALUE_TYPE_MAP) {
      FlValue* value = fl_value_lookup_string(args, "application");
      if (value != nullptr && fl_value_get_type(value) == FL_VALUE_TYPE_STRING) {
        application = fl_value_get_string(value);
      }
      value = fl_value_lookup_string(args, "url");
      if (value != nullptr && fl_value_get_type(value) == FL_VALUE_TYPE_STRING) {
        url = fl_value_get_string(value);
      }
    }
    const gboolean url_ok =
        url != nullptr &&
        (g_str_has_prefix(url, "http://") || g_str_has_prefix(url, "https://") ||
         g_str_has_prefix(url, "file://"));
    if (application == nullptr || !g_path_is_absolute(application) || !url_ok) {
      response = FL_METHOD_RESPONSE(fl_method_error_response_new(
          "invalid", "播放器或播放地址无效", nullptr));
    } else if (g_file_test(application, G_FILE_TEST_IS_EXECUTABLE)) {
      g_autoptr(GError) error = nullptr;
      // This file is compiled as C++, so the flag bitmask needs a cast.
      g_autoptr(GSubprocessLauncher) launcher = g_subprocess_launcher_new(
          static_cast<GSubprocessFlags>(G_SUBPROCESS_FLAGS_STDOUT_SILENCE |
                                        G_SUBPROCESS_FLAGS_STDERR_SILENCE));
      GSubprocess* child = g_subprocess_launcher_spawn(
          launcher, &error, application, url, nullptr);
      if (child == nullptr) {
        response = FL_METHOD_RESPONSE(fl_method_error_response_new(
            "launch", "无法启动所选播放器", nullptr));
      } else {
        g_object_unref(child);
        response = FL_METHOD_RESPONSE(fl_method_success_response_new(
            fl_value_new_bool(TRUE)));
      }
    } else {
      response = FL_METHOD_RESPONSE(fl_method_error_response_new(
          "missing", "播放器程序不存在，请重新选择", nullptr));
    }
  } else if (g_strcmp0(name, "downloadProtectionStatus") == 0) {
    FlValue* status = fl_value_new_map();
    fl_value_set_string_take(status, "desktop", fl_value_new_bool(TRUE));
    fl_value_set_string_take(status, "wakeLockHeld",
                             fl_value_new_bool(self->sleep_inhibitor >= 0));
    response = FL_METHOD_RESPONSE(fl_method_success_response_new(status));
    fl_value_unref(status);
  } else {
    response = FL_METHOD_RESPONSE(fl_method_not_implemented_response_new());
  }
  fl_method_call_respond(method_call, response, nullptr);
}

static void setup_native_channel(MyApplication* self, FlView* view) {
  FlEngine* engine = fl_view_get_engine(view);
  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  self->native_channel = fl_method_channel_new(
      fl_engine_get_binary_messenger(engine), "com.asterlink.app/native",
      FL_METHOD_CODEC(codec));
  fl_method_channel_set_method_call_handler(
      self->native_channel, native_method_call_cb, self, nullptr);
}

// Mirrors the Windows and macOS bridges: only http(s) URLs and the app's own
// `wenxi://download|resolve` links are accepted, so a stray argument or a file
// path can never be handed to the downloader.
static gboolean is_download_launch(const gchar* value) {
  if (value == nullptr) return FALSE;
  const gsize length = strlen(value);
  if (length == 0 || length > 16384) return FALSE;
  for (gsize i = 0; i < length; i++) {
    const guchar ch = (guchar)value[i];
    if (ch <= 0x20 || ch == 0x7f) return FALSE;
  }
  return g_str_has_prefix(value, "https://") ||
         g_str_has_prefix(value, "http://") ||
         g_str_has_prefix(value, "wenxi://download?") ||
         g_str_has_prefix(value, "wenxi://download/?") ||
         g_str_has_prefix(value, "wenxi://resolve?") ||
         g_str_has_prefix(value, "wenxi://resolve/?");
}

// `asterlink <url>` or `asterlink --download <url>`, matching the Windows
// command-line contract.
static gchar* download_launch_argument(gchar** argv, gint argc) {
  if (argc == 1 && is_download_launch(argv[0])) return g_strdup(argv[0]);
  if (argc == 2 && (g_strcmp0(argv[0], "--download") == 0 ||
                    g_strcmp0(argv[0], "--open") == 0) &&
      is_download_launch(argv[1])) {
    return g_strdup(argv[1]);
  }
  return nullptr;
}

static void queue_open(MyApplication* self, const gchar* value) {
  if (!is_download_launch(value)) return;
  if (g_queue_get_length(self->pending_opens) >= 16) {
    g_free(g_queue_pop_head(self->pending_opens));
  }
  g_queue_push_tail(self->pending_opens, g_strdup(value));
  // The Dart side may not have registered its handler yet; the queued copy is
  // flushed on the next read either way, so this only shortens the wait.
  if (self->external_channel != nullptr) {
    fl_method_channel_invoke_method(self->external_channel,
                                    "externalOpenAvailable", nullptr, nullptr,
                                    nullptr, nullptr);
  }
}

static void external_method_call_cb(FlMethodChannel* channel,
                                    FlMethodCall* method_call,
                                    gpointer user_data) {
  MyApplication* self = MY_APPLICATION(user_data);
  g_autoptr(FlMethodResponse) response = nullptr;
  const gchar* name = fl_method_call_get_name(method_call);
  if (g_strcmp0(name, "takeExternalOpens") != 0) {
    response = FL_METHOD_RESPONSE(fl_method_not_implemented_response_new());
    fl_method_call_respond(method_call, response, nullptr);
    return;
  }
  FlValue* requests = fl_value_new_list();
  gchar* value = nullptr;
  while ((value = (gchar*)g_queue_pop_head(self->pending_opens)) != nullptr) {
    FlValue* item = fl_value_new_map();
    g_autofree gchar* id = g_strdup_printf("linux-%u", ++self->open_sequence);
    fl_value_set_string_take(item, "id", fl_value_new_string(id));
    fl_value_set_string_take(item, "launchUri", fl_value_new_string(value));
    fl_value_append_take(requests, item);
    g_free(value);
  }
  response = FL_METHOD_RESPONSE(fl_method_success_response_new(requests));
  fl_value_unref(requests);
  fl_method_call_respond(method_call, response, nullptr);
}

static void setup_external_channel(MyApplication* self, FlView* view) {
  FlEngine* engine = fl_view_get_engine(view);
  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  self->external_channel = fl_method_channel_new(
      fl_engine_get_binary_messenger(engine), "com.asterlink.app/external_open",
      FL_METHOD_CODEC(codec));
  fl_method_channel_set_method_call_handler(
      self->external_channel, external_method_call_cb, self, nullptr);
  // A link that arrived before this point was kept in queued_open.
  if (self->queued_open != nullptr) {
    queue_open(self, self->queued_open);
    g_clear_pointer(&self->queued_open, g_free);
  }
}

// Implements GApplication::activate.
static void my_application_activate(GApplication* application) {
  MyApplication* self = MY_APPLICATION(application);
  GtkWindow* window =
      GTK_WINDOW(gtk_application_window_new(GTK_APPLICATION(application)));

  // Use a header bar when running in GNOME as this is the common style used
  // by applications and is the setup most users will be using (e.g. Ubuntu
  // desktop).
  // If running on X and not using GNOME then just use a traditional title bar
  // in case the window manager does more exotic layout, e.g. tiling.
  // If running on Wayland assume the header bar will work (may need changing
  // if future cases occur).
  gboolean use_header_bar = TRUE;
#ifdef GDK_WINDOWING_X11
  GdkScreen* screen = gtk_window_get_screen(window);
  if (GDK_IS_X11_SCREEN(screen)) {
    const gchar* wm_name = gdk_x11_screen_get_window_manager_name(screen);
    if (g_strcmp0(wm_name, "GNOME Shell") != 0) {
      use_header_bar = FALSE;
    }
  }
#endif
  if (use_header_bar) {
    GtkHeaderBar* header_bar = GTK_HEADER_BAR(gtk_header_bar_new());
    gtk_widget_show(GTK_WIDGET(header_bar));
    gtk_header_bar_set_title(header_bar, "文析助手");
    gtk_header_bar_set_show_close_button(header_bar, TRUE);
    gtk_window_set_titlebar(window, GTK_WIDGET(header_bar));
  } else {
    gtk_window_set_title(window, "文析助手");
  }

  // Match the Windows runner: a 1100x780 default and a 720x520 minimum, which
  // is also what window_manager applies once the Dart side starts.
  gtk_window_set_default_size(window, 1100, 780);
  GdkGeometry geometry = {};
  geometry.min_width = 720;
  geometry.min_height = 520;
  gtk_window_set_geometry_hints(window, nullptr, &geometry,
                                GDK_HINT_MIN_SIZE);

  // Use the bundled app icon for the window so task switchers do not show a
  // generic placeholder. The asset bundle sits beside the executable, and a
  // missing file must not stop startup (e.g. in headless sessions).
  g_autofree gchar* exe_path = g_file_read_link("/proc/self/exe", nullptr);
  if (exe_path != nullptr) {
    g_autofree gchar* exe_dir = g_path_get_dirname(exe_path);
    g_autofree gchar* icon_path = g_build_filename(
        exe_dir, "data", "flutter_assets", "assets", "icons", "app.png",
        nullptr);
    gtk_window_set_icon_from_file(window, icon_path, nullptr);
  }

  g_autoptr(FlDartProject) project = fl_dart_project_new();
  fl_dart_project_set_dart_entrypoint_arguments(
      project, self->dart_entrypoint_arguments);

  FlView* view = fl_view_new(project);
  GdkRGBA background_color;
  // Background defaults to black, override it here if necessary, e.g. #00000000
  // for transparent.
  gdk_rgba_parse(&background_color, "#000000");
  fl_view_set_background_color(view, &background_color);
  gtk_widget_show(GTK_WIDGET(view));
  gtk_container_add(GTK_CONTAINER(window), GTK_WIDGET(view));

  // Show the window when Flutter renders.
  // Requires the view to be realized so we can start rendering.
  g_signal_connect_swapped(view, "first-frame", G_CALLBACK(first_frame_cb),
                           self);
  gtk_widget_realize(GTK_WIDGET(view));

  fl_register_plugins(FL_PLUGIN_REGISTRY(view));

  setup_theme_channel(self, view);
  setup_native_channel(self, view);
  setup_external_channel(self, view);

  // The app defaults to the system brightness; the Dart side refines this as
  // soon as the theme resolves, including a forced light or dark setting.
  GtkSettings* settings = gtk_settings_get_default();
  gboolean prefer_dark = FALSE;
  g_object_get(settings, "gtk-application-prefer-dark-theme", &prefer_dark,
               nullptr);
  apply_header_bar_theme(self, prefer_dark);

  gtk_widget_grab_focus(GTK_WIDGET(view));
}

// Implements GApplication::command_line.
// G_APPLICATION_HANDLES_COMMAND_LINE delivers every launch here, including the
// ones D-Bus forwards from `asterlink <url>` while a window is already open.
// That is what lets a link reuse the running instance instead of dying on the
// data-directory lock.
static gint my_application_command_line(GApplication* application,
                                        GApplicationCommandLine* command_line) {
  MyApplication* self = MY_APPLICATION(application);
  gint argc = 0;
  gchar** argv = g_application_command_line_get_arguments(command_line, &argc);
  gchar** args = argc > 0 ? argv + 1 : argv;
  const gint nargs = argc > 0 ? argc - 1 : 0;

  if (!self->started) {
    self->started = TRUE;
    self->dart_entrypoint_arguments = g_strdupv(args);
    self->sleep_inhibitor = -1;
    self->pending_opens = g_queue_new();
    self->queued_open = download_launch_argument(args, nargs);
    g_application_activate(application);
  } else {
    gchar* link = download_launch_argument(args, nargs);
    if (link != nullptr) {
      queue_open(self, link);
      g_free(link);
    }
    GList* windows = gtk_application_get_windows(GTK_APPLICATION(application));
    if (windows != nullptr) gtk_window_present(GTK_WINDOW(windows->data));
  }
  g_strfreev(argv);
  return 0;
}

// Implements GApplication::startup.
static void my_application_startup(GApplication* application) {
  // MyApplication* self = MY_APPLICATION(object);

  // Perform any actions required at application startup.

  G_APPLICATION_CLASS(my_application_parent_class)->startup(application);
}

// Implements GApplication::shutdown.
static void my_application_shutdown(GApplication* application) {
  // MyApplication* self = MY_APPLICATION(object);

  // Perform any actions required at application shutdown.

  G_APPLICATION_CLASS(my_application_parent_class)->shutdown(application);
}

// Implements GObject::dispose.
static void my_application_dispose(GObject* object) {
  MyApplication* self = MY_APPLICATION(object);
  release_sleep_inhibitor(self);
  g_clear_object(&self->theme_channel);
  g_clear_object(&self->native_channel);
  g_clear_object(&self->external_channel);
  g_clear_pointer(&self->queued_open, g_free);
  if (self->pending_opens != nullptr) {
    g_queue_free_full(self->pending_opens, g_free);
    self->pending_opens = nullptr;
  }
  g_clear_object(&self->theme_provider);
  g_clear_pointer(&self->dart_entrypoint_arguments, g_strfreev);
  G_OBJECT_CLASS(my_application_parent_class)->dispose(object);
}

static void my_application_class_init(MyApplicationClass* klass) {
  G_APPLICATION_CLASS(klass)->activate = my_application_activate;
  G_APPLICATION_CLASS(klass)->command_line = my_application_command_line;
  G_APPLICATION_CLASS(klass)->startup = my_application_startup;
  G_APPLICATION_CLASS(klass)->shutdown = my_application_shutdown;
  G_OBJECT_CLASS(klass)->dispose = my_application_dispose;
}

static void my_application_init(MyApplication* self) {}

MyApplication* my_application_new() {
  // Set the program name to the application ID, which helps various systems
  // like GTK and desktop environments map this running application to its
  // corresponding .desktop file. This ensures better integration by allowing
  // the application to be recognized beyond its binary name.
  g_set_prgname(APPLICATION_ID);

  return MY_APPLICATION(g_object_new(my_application_get_type(),
                                     "application-id", APPLICATION_ID, "flags",
                                     G_APPLICATION_HANDLES_COMMAND_LINE,
                                     nullptr));
}
