# Changelog

Versions 1.0.0 to 1.6.1 were built and used on game version 2.31; 1.7.0 and 1.7.1 are for 2.5. Shelved versions never replaced the installed one. Where only a range of dates is known, the range is given.

## 1.7.1 - 2026-11-23
### Fixed
- Second fix for driving and autodrive after 1.7.0 failed its in-game test. The device is bound to the player's body root with "keep world transform" on, as the game does, so it rides with the player and the car inside the engine.
- The device camera is lined up against the player's rendered view: measured before the zoom, measured again after it, and the difference taken out through local transforms. The gap between the placed and the rendered pose while driving is learned and stored in `config.json`.
- Getting in or out of a vehicle, or switching the vehicle camera, closes the screen.
- If the binding does not hold, the device falls back to the per-frame follow of 1.6.1, with the same line-up.

In use in the author's game and working; tested.

## 1.7.0 - 2026-11-23
### Changed
- First engine binding for driving and autodrive (to a camera component, "keep world transform" off). Refuses during the autodrive cinematic camera.

Failed its in-game test: in a car the view came from the footwell or from behind the seat. See the engineering notes in the README.

## 1.6.1 - 2026-11-07
### Fixed
- Unticking "Darken screen" in the window works again.
- A hit on the player while the screen is open no longer deletes the device during the camera blend-out.
- "Reload all mods" while the screen is open releases the camera first; the new instance deletes the old device afterwards.
- Spawning times out even when the entity exists. Opening is refused while controlling a security camera or turret.
- Minimum screen distance 0.115 m, so on foot the screen is placed exactly as in 1.3.0.

## 1.6.0 - 2026-11-07
### Fixed
- Works in vehicles: the screen is never closer than the device camera's near plane; where it would need to be, the device camera's field of view is narrowed instead. Built on 1.3.0.

Used in vehicles; a fault remained while driving.

## 1.4.0 and 1.5.0 - 2026-11-04
- 1.4.0 preloaded the device's resources; it changed nothing in game. 1.5.0 kept one device alive between opens. Both were reverted; 1.6.0 is built on 1.3.0.

## 1.3.0 - 2026-11-04
### Added
- Screen dimmer: a toggle and a darkness slider that put one dark grading layer over the whole picture through DigitalVixen Core. Optional hotkey.

Installed and used in game. 1.3.1 and 1.3.2 (keeping the screen bright under the dimmer) both failed in game and were shelved.

## 1.2.0 - 2026-11-03 to 2026-11-04
- A background opacity slider. It changed nothing in game; shelved.

## 1.1.0 - 2026-11-03
### Added
- Opacity slider (see-through screen material) and a panel width slider up to the full view.
### Fixed
- "Unstick" no longer deletes a device whose camera is active (that crashed the game in 1.0.0).

Confirmed working in game.

## 1.0.0 - 2026-11-03
- First version: a computer screen in the optics on one key, following the player.

First in-game test: worked, except that "Unstick" crashed the game.
