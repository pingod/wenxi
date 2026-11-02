#include "my_application.h"

#include <flutter_linux/flutter_linux.h>
#ifdef GDK_WINDOWING_X11
#include <gdk/gdkx.h>
#endif

#include "flutter/generated_plugin_registrant.h"

struct _MyApplication {
  GtkApplication parent_instance;
  char** dart_entrypoint_arguments;
  FlMethodChannel* theme_channel;
  GtkCssProvider* theme_provider;
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

  // The app defaults to the system brightness; the Dart side refines this as
  // soon as the theme resolves, including a forced light or dark setting.
  GtkSettings* settings = gtk_settings_get_default();
  gboolean prefer_dark = FALSE;
  g_object_get(settings, "gtk-application-prefer-dark-theme", &prefer_dark,
               nullptr);
  apply_header_bar_theme(self, prefer_dark);

  gtk_widget_grab_focus(GTK_WIDGET(view));
}

// Implements GApplication::local_command_line.
static gboolean my_application_local_command_line(GApplication* application,
                                                  gchar*** arguments,
                                                  int* exit_status) {
  MyApplication* self = MY_APPLICATION(application);
  // Strip out the first argument as it is the binary name.
  self->dart_entrypoint_arguments = g_strdupv(*arguments + 1);

  g_autoptr(GError) error = nullptr;
  if (!g_application_register(application, nullptr, &error)) {
    g_warning("Failed to register: %s", error->message);
    *exit_status = 1;
    return TRUE;
  }

  g_application_activate(application);
  *exit_status = 0;

  return TRUE;
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
  g_clear_object(&self->theme_channel);
  g_clear_object(&self->theme_provider);
  g_clear_pointer(&self->dart_entrypoint_arguments, g_strfreev);
  G_OBJECT_CLASS(my_application_parent_class)->dispose(object);
}

static void my_application_class_init(MyApplicationClass* klass) {
  G_APPLICATION_CLASS(klass)->activate = my_application_activate;
  G_APPLICATION_CLASS(klass)->local_command_line =
      my_application_local_command_line;
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
                                     G_APPLICATION_NON_UNIQUE, nullptr));
}
