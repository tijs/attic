# Ladder 0.7.0 integration

Release: https://github.com/tijs/ladder/releases/tag/v0.7.0
Upstream issue: https://github.com/tijs/ladder/issues/1
Source commit: `e48e8e800596bbb7529cd6b279bd76cf5dbc3f7a`

Attic now requires Ladder 0.7.0 or newer and commits Package.resolved so CI and
source checkouts share the tested release revision. The targeted update changed
only Ladder; all previously resolved transitive versions are retained. Swift 6.1
and macOS 14 remain the minimum requirements.

`LadderAlbumIntegrationTests` builds disposable synthetic SQLite databases with
the legacy Z_33ASSETS and reported macOS 27 Z_34ASSETS relationships. It passes
each through the public LadderKit enrichment API, resolves a cloud ID containing
reserved characters, and checks Attic's encoded/decoded metadata. Missing and
unsupported album joins preserve the filename, description and type. Database
bytes are unchanged by enrichment.

This is synthetic integration evidence. A copied/sanitized database from a real
macOS 27 Photos library has not been supplied or validated. No live Photos
library is accessed by these tests.

Validation: all 331 Swift tests pass, SwiftFormat passes, and SwiftLint succeeds
with existing warnings. The upstream release includes the schema regression
fixtures and passed its 96 tests. Attic's existing classification checks are
compatible with Ladder's removal of ExportError.unavailable.
