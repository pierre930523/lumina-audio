import 'dart:convert';

/// Safely encodes a Dart string for embedding inside an HTML `<script>` block.
String _safeJsString(String value) =>
    jsonEncode(value).replaceAll('</', r'<\/').replaceAll('<!--', r'<\!--');

/// Builds an HTML page using Apple MusicKit JS v3 to authorize a real
/// `musicUserToken` and POST it back to [callbackUrl].
String buildMusicKitAuthHtml(String developerToken, String callbackUrl) {
  final devTokenJson = _safeJsString(developerToken);
  final callbackJson = _safeJsString(callbackUrl);

  return '''<!DOCTYPE html>
<html lang="zh-Hant">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Lumina Audio — Apple Music 授權</title>
  <script src="https://js-cdn.music.apple.com/musickit/v3/musickit.js" async></script>
  <style>
    body { margin:0; font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif; background:#0B0F17; color:#F8FAFC; display:flex; align-items:center; justify-content:center; min-height:100vh; }
    .card { max-width:480px; padding:32px; border-radius:16px; background:#111827; border:1px solid rgba(250,36,60,0.35); box-shadow:0 20px 50px rgba(0,0,0,0.5); }
    h1 { margin:0 0 10px; font-size:20px; color:#FA243C; }
    p { margin:0 0 18px; font-size:14px; line-height:1.6; color:#CBD5E1; }
    button { appearance:none; border:0; border-radius:10px; padding:10px 18px; background:#FA243C; color:#FFFFFF; font-size:14px; font-weight:600; cursor:pointer; }
    button:disabled { opacity:0.55; cursor:wait; }
    .status { margin-top:14px; font-size:13px; color:#94A3B8; }
  </style>
</head>
<body>
  <div class="card">
    <h1>Apple Music 帳號授權</h1>
    <p>請透過 Apple MusicKit 完成登入授權，Lumina Audio 將透過本機回傳通道接收您的 Music-User-Token。</p>
    <button id="authBtn" type="button">使用 Apple 帳號登入</button>
    <div id="status" class="status">正在載入 Apple MusicKit JS...</div>
  </div>
  <script>
    (function () {
      const developerToken = $devTokenJson;
      const callbackUrl = $callbackJson;
      const statusEl = document.getElementById('status');
      const authBtn = document.getElementById('authBtn');
      let configured = false;

      async function configureMusicKit() {
        if (configured || !window.MusicKit) return;
        await window.MusicKit.configure({
          developerToken: developerToken,
          app: { name: 'Lumina Audio', build: '0.2.1' }
        });
        configured = true;
        statusEl.textContent = 'MusicKit 已就緒，正在開啟 Apple 登入視窗...';
      }

      async function runAuthorize() {
        authBtn.disabled = true;
        try {
          await configureMusicKit();
          const music = window.MusicKit.getInstance();
          const musicUserToken = await music.authorize();
          if (!musicUserToken) {
            throw new Error('未取得有效的 Music-User-Token');
          }
          statusEl.textContent = '授權成功，正在傳送憑證至 Lumina Audio...';
          const resp = await fetch(callbackUrl, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ musicUserToken: musicUserToken })
          });
          if (!resp.ok) {
            throw new Error('回傳至 Lumina Audio 失敗（HTTP ' + resp.status + '）');
          }
          statusEl.textContent = '已完成授權！您可以關閉此瀏覽器分頁並返回 Lumina Audio。';
        } catch (err) {
          const msg = (err && err.message) ? err.message : String(err);
          statusEl.textContent = '授權失敗：' + msg;
          authBtn.disabled = false;
          try {
            await fetch(callbackUrl, {
              method: 'POST',
              headers: { 'Content-Type': 'application/json' },
              body: JSON.stringify({ error: msg })
            });
          } catch (_) {}
        }
      }

      authBtn.addEventListener('click', runAuthorize);
      if (window.MusicKit) {
        runAuthorize();
      } else {
        document.addEventListener('musickitloaded', runAuthorize, { once: true });
      }
    })();
  </script>
</body>
</html>''';
}
