# Citation, License & Publishing Notes

Notes for forking, citing, and republishing Icarust (including as an open-source
repo and Docker container, e.g. under the **alkanlab** DockerHub org).

> ⚠️ Not legal advice. MPL-2.0 is straightforward, but for high-stakes use confirm
> with a lawyer, and it's courteous to give the original authors a heads-up.

## Original work — cite this

Icarust is by the **Loose Lab (University of Nottingham)**. See [CITATION.cff](CITATION.cff).

- Authors: Rory Munro, Alexander Payne, Matthew Loose
- Title: *Icarust, a real-time simulator for Oxford Nanopore adaptive sampling.*
- DOI: `10.1101/2023.05.16.540986`
- Upstream: https://github.com/LooseLab/Icarust

Citation is a *request* (not a license term), but academically you should keep
crediting the original authors. Keep `CITATION.cff`; add alkanlab / yourself as a
contributor rather than removing the originals.

## License — MPL 2.0 (weak, file-level copyleft)

Full text: [LICENSE.md](LICENSE.md). MPL-2.0 is OSI-approved open source and is much
lighter than GPL — it does **not** infect the whole project, only individual files.

### You may
- Fork, fix, and publish your fork as a public open-source repo.
- Build and push a Docker image (e.g. to alkanlab DockerHub).
- Use it commercially / in lab pipelines.
- Add new files under a different license, and combine with other-licensed code.

### You must
1. **Keep the license + notices** — leave `LICENSE.md` in place; don't strip
   copyright/author notices. MPL-covered files stay MPL.
2. **Changes to existing MPL files stay MPL and must be source-available** — making
   your fork public on GitHub satisfies this automatically.
3. **Shipping the Docker image = distributing "Executable Form"** — MPL §3.2 requires
   telling recipients how to get the corresponding MPL source. Put a line in the
   DockerHub description / a `NOTICE` in the image, e.g.:
   > Based on Icarust (MPL-2.0). Source: https://github.com/alkanlab/<yourfork>. Licensed under MPL-2.0.
4. **Only MPL files are copyleft** — brand-new standalone files you write may be
   licensed differently (keeping everything MPL is simplest).
5. **No trademark/name grant** — the license covers code, not the "Icarust" name or
   the authors' identities. Don't imply the original authors endorse your fork; mark
   it clearly as "a fork of Icarust".

## Publish checklist
- [ ] Public fork on GitHub; `LICENSE.md` (MPL-2.0) kept as-is
- [ ] `README` notes it's a fork of LooseLab/Icarust (+ link) and summarizes your changes
- [ ] `CITATION.cff` retained; add alkanlab / your name as contributor
- [ ] DockerHub description: MPL-2.0 + link to the source fork
- [ ] Optional: add `// SPDX-License-Identifier: MPL-2.0` + copyright header to modified files
- [ ] Optional: add `license = "MPL-2.0"` to `Cargo.toml` (currently missing; needed for crates.io)
</content>
