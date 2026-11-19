// l4c: Firefox 针对 4G 内存 + eMMC 的默认设置（用户在 about:config 里改过的值优先）
pref("browser.cache.disk.enable", false);
pref("browser.cache.memory.enable", true);
pref("browser.cache.memory.capacity", 65536);
pref("browser.sessionstore.interval", 60000);
pref("browser.tabs.unloadOnLowMemory", true);
pref("dom.ipc.processCount", 4);
pref("media.ffmpeg.vaapi.enabled", true);
pref("media.hardware-video-decoding.force-enabled", true);
