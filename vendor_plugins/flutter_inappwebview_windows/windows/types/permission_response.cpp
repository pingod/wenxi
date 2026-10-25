#include "permission_response.h"

namespace flutter_inappwebview_plugin
{
  PermissionResponse::PermissionResponse(const std::optional<std::vector<int64_t>>& resources, const std::optional<PermissionResponseActionType>& action)
    : resources(resources), action(action)
  {}

  std::optional<std::shared_ptr<PermissionResponse>> PermissionResponse::fromEncodableValue(
    const flutter::EncodableValue* value)
  {
    if (!value) return std::nullopt;
    const auto* map = std::get_if<flutter::EncodableMap>(value);
    if (!map) return std::nullopt;

    const auto integer = [](const flutter::EncodableValue& field) -> std::optional<int64_t> {
      if (const auto* number = std::get_if<int32_t>(&field)) return *number;
      if (const auto* number = std::get_if<int64_t>(&field)) return *number;
      return std::nullopt;
    };
    const auto actionField = map->find(flutter::EncodableValue("action"));
    if (actionField == map->end()) return std::nullopt;
    std::optional<int64_t> action;
    // Preserve the plugin's explicit action:null -> browser prompt behavior.
    // A null reply is different: it falls back to denying the request.
    if (!actionField->second.IsNull()) {
      action = integer(actionField->second);
      if (!action || *action < PermissionResponseActionType::deny ||
          *action > PermissionResponseActionType::prompt) return std::nullopt;
    }

    std::optional<std::vector<int64_t>> resources;
    const auto resourceField = map->find(flutter::EncodableValue("resources"));
    if (resourceField != map->end() && !resourceField->second.IsNull()) {
      const auto* list = std::get_if<flutter::EncodableList>(&resourceField->second);
      if (!list) return std::nullopt;
      resources.emplace();
      resources->reserve(list->size());
      for (const auto& field : *list) {
        const auto resource = integer(field);
        if (!resource) return std::nullopt;
        resources->push_back(*resource);
      }
    }
    return std::make_shared<PermissionResponse>(resources,
      PermissionResponseActionTypeFromInteger(action));
  }

  flutter::EncodableMap PermissionResponse::toEncodableMap() const
  {
    return flutter::EncodableMap{
      {"resources", make_fl_value(resources)},
      {"action", make_fl_value(action)},
    };
  }
}
