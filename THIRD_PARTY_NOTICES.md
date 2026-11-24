# Third-party notices

DebianRunner is maintained by Eray Arslan (`erayarslan`) as a headless Debian minimal fork of LinuxRunner (Leminos / `mxhm11cr`), which derives from iSH (Theodore Dubois and contributors) through ios-linuxkit (Rui Carmo and contributors). Preserve [LICENSE.md](LICENSE.md), [LICENSE.IOS](LICENSE.IOS), the [full GPL texts](licenses/), all source copyright notices, and the in-app Notices & Credits. The combined application is GPL-3.0-covered; the upstream contribution-specific GPL-2.0 terms are retained without extending them to every downstream addition.

## Components in the application

| Component | Retained source / notice | Terms |
| --- | --- | --- |
| libarchive | `deps/libarchive`, pinned revision in `SOURCE_ORIGIN.txt` | BSD-style; per-file terms in COPYING |
| hterm / libapps | `deps/libapps` | BSD-3-Clause and component-specific terms |
| xterm.js and addons | `app/terminal/xterm-vendor/LICENSES.md`, VENDORED.txt | MIT; package versions recorded with the bundle |
| Ghostty Web | `app/terminal/ghostty-web-VENDORED.txt`, `Support.bundle/terminal-notices.txt` | MIT; vendor record describes local WKWebView patches |
| Fira Code and JetBrains Mono Nerd Fonts | Font VENDORED.txt files and `Support.bundle/terminal-notices.txt` | SIL OFL-1.1 and relevant Nerd Fonts notices |
| LZMA API headers | `deps/lzma-api/COPYING`, provenance.json | Header-specific public-domain notice; system liblzma linked separately |
| SQLite and Apple system libraries | Platform libraries | Their respective upstream/platform terms |

The app bundles `Support.bundle/terminal-notices.txt` and xterm's `LICENSES.md`. Retain these notices in the source and packaged application.

The rootfs patch bundle (`app/RootfsPatch.bundle`) contains `wasm-polyfill.js` and `fetch-polyfill.js`. The former describes an llhttp parser reimplementation; the upstream llhttp MIT notice is retained in `licenses/llhttp-MIT.txt`.

## Downloaded Debian software

Debian GNU/Linux 13 (trixie) minimal packages are downloaded on-device from official Debian mirrors (`deb.debian.org`) using the authenticated manifest in `app/LinuxRunner/DebianSupport.bundle`. Downloaded packages keep their own licenses and notices (`/usr/share/doc/<package>/copyright` inside Debian).

## Source availability

The application source, build scripts, and dependency revisions are retained in the repository. [SOURCE_ORIGIN.txt](SOURCE_ORIGIN.txt) records the upstream lineage and dependency commits. Submodule contents are not included in GitHub's automatic source archives; initialize the pinned submodules (`deps/libapps`, `deps/libarchive`) when building from a clone.
