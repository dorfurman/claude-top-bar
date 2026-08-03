<div align="center"><pre>
&nbsp;&nbsp;&nbsp;____&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;_&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;____&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;
&nbsp;&nbsp;/&nbsp;___|_&nbsp;__&nbsp;__&nbsp;_|&nbsp;|__&nbsp;|&nbsp;__&nbsp;)&nbsp;&nbsp;__&nbsp;_&nbsp;_&nbsp;__&nbsp;
&nbsp;|&nbsp;|&nbsp;&nbsp;&nbsp;|&nbsp;'__/&nbsp;_`&nbsp;|&nbsp;'_&nbsp;\|&nbsp;&nbsp;_&nbsp;\&nbsp;/&nbsp;_`&nbsp;|&nbsp;'__|
&nbsp;|&nbsp;|___|&nbsp;|&nbsp;|&nbsp;(_|&nbsp;|&nbsp;|_)&nbsp;|&nbsp;|_)&nbsp;|&nbsp;(_|&nbsp;|&nbsp;|&nbsp;&nbsp;&nbsp;
&nbsp;&nbsp;\____|_|&nbsp;&nbsp;\__,_|_.__/|____/&nbsp;\__,_|_|&nbsp;&nbsp;&nbsp;
</pre></div>

<h1 align="center">CrabBar</h1>

<p align="center">
  <b>🦀 Claude Code usage, live in your macOS menu bar</b><br>
  <i>Real limit percentages, reset times, projections, and live chats — one click away</i>
</p>

<p align="center">
  <img src="docs/icon.png" width="128" alt="CrabBar icon">
</p>

<p align="center">
  <img src="docs/pill.gif" width="189" alt="CrabBar menu bar pill">
</p>

<p align="center">
  <img src="docs/popover.png" width="300" alt="CrabBar popover">
</p>

## Install

1. Download `CrabBar-x.y.z.zip` from the [latest release](https://github.com/dorfurman/claude-top-bar/releases/latest)
2. Unzip and drag **CrabBar.app** into **Applications**
3. Launch it, click the pill, and sign in with Claude

Signed and notarized — no Gatekeeper warnings. Requires macOS 14+ on Apple silicon.
Later updates install themselves: click the update line in the popover (or the right-click
menu) and CrabBar downloads the new release, replaces itself in **Applications**, and restarts —
no second copy, no second menu bar icon.

## Build from source

Requires Xcode command line tools (Apple silicon).

    git clone https://github.com/dorfurman/claude-top-bar
    cd claude-top-bar
    ./build.sh
    open CrabBar.app

Without a Developer ID cert the app is ad-hoc signed — fine on your own Mac.

## Features

- **Real numbers, not estimates** — the percentage of your 5-hour limit comes straight
  from claude.ai, the same figure Claude Code's `/usage` shows
- **Every window your plan has** — weekly all-models, weekly Opus/Sonnet, each with its
  own meter and reset time
- **Projection** — "at this rate you run out in 52m"
- **Local breakdown** — which model is eating the window, activity per 10 minutes,
  and daily bars for the last 7 days
- **Live chats** — sessions active in the last 30 minutes, green while Claude is
  working, grey once it's waiting on you
- **Notifications** when you cross usage thresholds
- **Clawd** — the crab in your menu bar plays the occasional trick, and there may or
  may not be a hidden game of Crab Invaders

Left-click the pill for the popover, right-click for the menu. Settings covers the
pill display, notifications, animations, and launch at login.

