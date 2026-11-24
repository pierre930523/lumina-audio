#ifndef RUNNER_EXTERNAL_MUSIC_HOST_H_
#define RUNNER_EXTERNAL_MUSIC_HOST_H_

#include <windows.h>

#include <cstdint>
#include <functional>
#include <memory>
#include <string>

struct ExternalPlaybackStateEvent {
  int64_t epoch = 0;
  // One of: "loading", "playing", "paused", "stopped", "ended", "error".
  std::string status;
  int64_t position_ms = 0;
  int64_t duration_ms = 0;
  std::string error;
};

struct ExternalPlaybackConfigureArgs {
  std::string developer_token;
  std::string music_user_token;
  std::string storefront;
};

struct ExternalPlaybackPlayArgs {
  std::string track_uri;
  std::string preview_url;
  std::string external_web_url;
  int64_t epoch = 0;
};

// Hosts an isolated, hidden WebView2 controller window for external Apple Music
// playback (MusicKit JS v3 / HTML5 <audio>) completely separate from the Rust
// native audio pipeline.
class ExternalMusicHost {
 public:
  using StateCallback = std::function<void(const ExternalPlaybackStateEvent&)>;

  static bool IsWebView2Available();

  static std::unique_ptr<ExternalMusicHost> Create(HWND owner_hwnd,
                                                   StateCallback on_state);

  ~ExternalMusicHost();

  ExternalMusicHost(const ExternalMusicHost&) = delete;
  ExternalMusicHost& operator=(const ExternalMusicHost&) = delete;

  bool IsAvailable() const;
  bool Configure(const ExternalPlaybackConfigureArgs& args,
                 std::string* error_out);
  bool Play(const ExternalPlaybackPlayArgs& args, std::string* error_out);
  bool Pause(int64_t epoch, std::string* error_out);
  bool Resume(int64_t epoch, std::string* error_out);
  bool Seek(int64_t position_ms, int64_t epoch, std::string* error_out);
  bool SetVolume(double volume, std::string* error_out);
  bool Stop(int64_t epoch, std::string* error_out);

  void Shutdown();

 private:
  struct Impl;
  explicit ExternalMusicHost(std::shared_ptr<Impl> impl);
  std::shared_ptr<Impl> impl_;
};

#endif  // RUNNER_EXTERNAL_MUSIC_HOST_H_
