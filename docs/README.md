# docs — how the bridge works

Documentation for the Strata → LM Studio bridge. It describes the two
engine-extension routes (PT and GGUF), how to install them, and the limits of
what they can show.

- [`how-it-works.md`](how-it-works.md) — the two routes, the engine-extension
  seam, and why each exists.
- [`install.md`](install.md) — install + rollback procedure.
- [`badges.md`](badges.md) — what metadata badges each route can advertise.
- [`reasoning-effort.md`](reasoning-effort.md) — how reasoning effort is
  forwarded to Strata.

The bridge proxies
[Strata](https://github.com/Niko1221/Strata)'s already-running serving gateway;
it never loads model weights into LM Studio.
