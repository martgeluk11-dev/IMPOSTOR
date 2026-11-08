# IMPOSTOR

A browser-based social deduction party game for 2–8 players.

## Run it

Open `index.html` in a browser, or publish the repository with GitHub Pages:

1. Open **Settings → Pages**.
2. Under **Build and deployment**, choose **Deploy from a branch**.
3. Select **main** and **/(root)**, then save.
4. Open the Pages URL GitHub gives you.

Every player opens the same URL on their own device. One player creates a room and shares the six-character room code.

## Multiplayer notes

Phase 1 uses PeerJS for browser-to-browser connections. The room creator's browser is the authoritative host for the match, so the host must stay online and keep the tab open. PeerJS's public signaling service is used to connect players; network/firewall restrictions can prevent some connections. This is an early playable foundation, not a production-secure dedicated-server setup.

## Current scope

- 2–8 players and room codes
- Ready-up lobby
- Five timed hint rounds
- Secret word is sent privately to each crew member; the impostor receives only the category
- Private voting, tie-breaking Judge, final impostor guess and results
- Responsive layout for desktop and mobile

Coins, cosmetics, avatars and the final visual polish are intentionally left for later phases.
