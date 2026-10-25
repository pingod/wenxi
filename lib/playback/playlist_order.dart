import '../core/natural_name.dart';
import '../domain/playback.dart';

String playlistOrderLabel(PlaybackPlaylistOrder order) => switch (order) {
  PlaybackPlaylistOrder.source => '文件顺序',
  PlaybackPlaylistOrder.ascending => '集数正序',
  PlaybackPlaylistOrder.descending => '集数倒序',
};

List<int> orderedPlaybackIndices(
  List<PlaybackEntry> entries,
  PlaybackPlaylistOrder order,
) {
  final result = List.generate(entries.length, (index) => index);
  if (order == PlaybackPlaylistOrder.source) return List.unmodifiable(result);
  final names = entries.map((entry) => NaturalName(entry.name)).toList();
  result.sort((a, b) {
    final compared = names[a].compareTo(names[b]);
    // Duplicate names retain their source order in either direction.
    if (compared == 0) return a.compareTo(b);
    return order == PlaybackPlaylistOrder.ascending ? compared : -compared;
  });
  return List.unmodifiable(result);
}
