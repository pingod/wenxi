import '../core/json.dart';

bool tianyiNeedsAccessCode(Json info) {
  // Public shares also return needAccessCode=1. shareType=1 explicitly
  // permits anonymous browsing; shareType=3 identifies protected shares.
  if (info.integer('shareType') == 1) return false;
  if (info.integer('shareType') == 3) return true;
  return switch (info['needAccessCode']) {
    true || 'true' || 1 || '1' => true,
    _ => false,
  };
}
