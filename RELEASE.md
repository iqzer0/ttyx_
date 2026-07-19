ttyx_ Release Process
=====================

## Pre-release

1. Ensure `master` branch is up to date:
   ```
   git checkout master && git pull
   ```

2. Verify all CI checks pass on the latest commit.

3. Update version number in:
   - `source/gx/ttyx/constants.d` (`APPLICATION_VERSION`)

4. Write NEWS entries:
   ```
   git shortlog <previous-tag>.. | grep -i -v trivial | grep -v Merge > NEWS.new
   ```
   Then manually edit `NEWS` following this format:
   ```
   Version X.Y.Z
   ~~~~~~~~~~~~~~
   Released: YYYY-MM-DD

   Features:

   Bugfixes:

   Build & Performance:

   Miscellaneous:
   ```
   Note: `appstreamcli news-to-metainfo` only accepts standard section names
   (Features, Bugfixes, Miscellaneous, Notes, Contributors). Use `Features:`
   for security items prefixed with "Security:".

5. Run `extract-strings.sh` to update translation templates.

6. Commit all release prep changes:
   ```
   git commit -a -m "Release version X.Y.Z"
   git push
   ```

## Build and verify the release binary

7. Clean release build + test, and verify the install layout:
    ```
    dub build --build=release --compiler=ldc2
    dub test --compiler=ldc2
    ./install.sh /tmp/ttyx-install-check/usr && rm -r /tmp/ttyx-install-check
    ```

## Sign and checksum

8. Create the source archive and signed checksums (the signed git tag is
   the primary integrity anchor; the checksums cover the exported archive):
    ```
    git archive --format=tar.gz --prefix=ttyx-X.Y.Z/ -o /tmp/ttyx-X.Y.Z.tar.gz vX.Y.Z
    sha256sum /tmp/ttyx-X.Y.Z.tar.gz > /tmp/ttyx-X.Y.Z_SHA256SUMS
    gpg --clearsign /tmp/ttyx-X.Y.Z_SHA256SUMS
    ```

## Publish

9. Create the GitHub release **with all assets in one shot** (do NOT
    upload assets after creation — GitHub's immutable releases will
    block subsequent uploads):
    ```
    gh release create vX.Y.Z -R gwelr/ttyx_ \
      --title "ttyx_ vX.Y.Z" \
      --target master \
      --notes-file /path/to/release-notes.md \
      /tmp/ttyx-X.Y.Z.tar.gz \
      /tmp/ttyx-X.Y.Z_SHA256SUMS.asc
    ```

## Post-release

10. Bump version to next development version in:
    - `source/gx/ttyx/constants.d`

11. Commit and push:
    ```
    git commit -a -m "chore: Post-release version bump to X.Y.Z+1"
    git push
    ```

## Verify

Users can verify release integrity with:
```
# Verify the signed tag (primary)
git verify-tag vX.Y.Z

# Or verify the archive: signature, then checksum
gpg --verify ttyx-X.Y.Z_SHA256SUMS.asc
sha256sum -c ttyx-X.Y.Z_SHA256SUMS.asc 2>/dev/null
```

Users install from source — see the Install page (`docs/install.md`).

## Notes

- All commits and tags are GPG-signed (key: `2CAAD12074F3C056`)
- CI Actions are pinned to commit SHAs (not mutable tags)
- Never create a release then try to add assets — always include them at creation time
