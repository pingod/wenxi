Synthetic HLS video and tone, with ten-second GOPs and MPEG-TS timestamps near
zero, matching the timing layout of affected Aliyun VOD streams. No account,
signed URL, or user media is included.

Generated with FFmpeg 4.2.2:

```sh
ffmpeg -f lavfi -i testsrc2=size=96x64:rate=25 \
  -f lavfi -i sine=frequency=440:sample_rate=44100 -t 21 \
  -c:v libx264 -pix_fmt yuv420p -g 250 -sc_threshold 0 -bf 3 -crf 38 \
  -c:a aac -b:a 24k -muxdelay 0 -muxpreload 0 \
  -hls_ts_options mpegts_copyts=1 -f hls -hls_time 10 -hls_list_size 0 \
  -hls_playlist_type vod -hls_segment_filename segment%d.ts video.m3u8
```

With the pinned libmpv test runtime, an explicit `start=0` causes the initial HLS
seek to fail and starts at about 10.02 seconds. Leaving the start unset reads the
first segment from its beginning (about 0.02 seconds).
