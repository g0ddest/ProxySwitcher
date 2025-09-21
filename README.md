# ProxyToggle (macOS menu bar app)

A tiny macOS menu bar app to quickly toggle system HTTP/HTTPS proxy settings and see the currently configured proxies at a glance.

- One-click toggle via the menu bar icon
- Right-click to view currently configured HTTP/HTTPS proxies
- Works across active network services (e.g., Wi‑Fi, Ethernet)

## Why this app?

On modern macOS versions, switching system proxies requires multiple steps through System Settings and affects each network service. If you regularly switch between direct internet access and a corporate or local proxy, doing this manually is slow and error-prone. ProxyToggle streamlines the workflow to a single click from the menu bar and provides instant visibility of which proxies are currently set.

## How proxy switching works in macOS (manual steps)

Without this app, you typically need to:
1. Open System Settings
2. Go to Network
3. Select your active network service (e.g., Wi‑Fi)
4. Click Details…
5. Open the Proxies tab
6. Check or uncheck “Web Proxy (HTTP)” and/or “Secure Web Proxy (HTTPS)”
7. Click OK.

Repeat for each network service you use (Wi‑Fi, Ethernet, etc.). This is time-consuming if you switch often.

## What ProxyToggle does

- Shows a menu bar icon indicating whether proxies are enabled (“network”) or disabled (“network.slash”).
- Left-click the icon to toggle HTTP/HTTPS proxies on/off across active services. It only flips the enable flags; it assumes you’ve already set the host and port values in System Settings at least once.
- Right-click the icon to open a menu listing the currently configured proxies:
  - If HTTP or HTTPS proxy is enabled and has a valid host and port, you’ll see entries like:
    - http: host:port
    - https: host:port
  - If none are enabled/configured, the menu shows “Proxy is disabled”.
- Runs as a menu bar app (no Dock icon).

## Requirements

- macOS 13+
- The app needs authorization to change network preferences (you’ll be prompted by macOS the first time).

## Installation

Prebuilt binary is available in Releases, download it, move it to Applications, and run. The first toggle will prompt for authorization.

Or you can build and run image from sources at any time.

## Usage

- Left-click the menu bar icon to toggle HTTP/HTTPS proxies.
- Right-click the menu bar icon to open the menu and view currently configured proxies or quit the app.
- The app uses your existing system proxy host/port values. To change host/port, use System Settings:
  - System Settings → Network → [Your Service] → Details… → Proxies → Web Proxy (HTTP) / Secure Web Proxy (HTTPS)

## Security and permissions

- The app uses macOS Authorization Services to request permission to modify network settings.
- If you run from Xcode and don’t see the authorization prompt, try launching the built app directly from Finder.
- If you see access errors (e.g., SCPreferences error 1003), ensure App Sandbox is disabled and try running outside Xcode.

## Limitations

- The app toggles enable/disable flags for HTTP and HTTPS proxies. It does not set or change host/port values; configure those once in System Settings.
- It applies changes to active, enabled network services with an interface (e.g., Wi‑Fi, Ethernet).
- Other proxy types (SOCKS, etc.) are not managed by this app.

## License

MIT License. See LICENSE for details.