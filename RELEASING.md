# Releasing

`versions.properties` is the single place the version is written. The build reads it for the
`-SNAPSHOT` default and refuses a version that is not `2.1.<branch>.<n>` for the branch `angle.pin`
takes ANGLE from; on every push to `main` the `tag-releases` workflow creates the tag
`v<version>` if it is not on origin yet and starts `publish`. Landing a bumped entry on `main` is the
release decision. Nobody types or pushes a tag.

```
2.1.8078.0   ANGLE from chromium/8078, as first packaged
2.1.8078.1   the same ANGLE rebuilt (a script change, a repackaging)
2.1.8200.0   a newer branch — move ANGLE_BRANCH and ANGLE_COMMIT in angle.pin in the same commit
```

What `publish` does, in order: verifies the tag and the version, builds the four slices on two
runners (`natives.yml`) with the licence inventory of each, merges them, **rehearses a consumer**
(`scripts/rehearse-consumer.sh`: publish to a file repository, resolve from it as a target-17
consumer, check every jar holds what the loader needs — before anything leaves the machine, because
Central keeps what it accepts), uploads the signed bundle, and drafts the GitHub release.

Nothing publishes itself: the deployment sits staged on the Central Portal until somebody presses
**Publish**, and the GitHub release is a draft.

## Trying a change before main

A push to `main` tags and publishes when `versions.properties` names a version without a tag, so a
change to the build is tried on a branch first: push the branch, then Actions → **ci** → Run
workflow on it. The repository's first push was such a branch (`first-build`), for the same reason:
`main` arriving first would have published a build no runner had made yet.

## Moving ANGLE

A new branch is a reason, not a routine: the toolkit compiles only its own shaders, so most of
ANGLE's security fixes, which are in the shader translator's handling of hostile input, do not reach
it. When there is one: take the head of the `chromium/<n>` branch of the Chromium release that is
stable that day, put both in `angle.pin`, run `ci` (it builds, inventories and tests all four
slices), read the inventory's differences from the last release's `THIRD_PARTY.txt`, and only then
bump the version. The toolkit then runs its own ES checks against the new payload before it adopts it.

## After a release

If the toolkit should pick the new payload up, bump `limn-angle-natives` in limn-toolkit's
`gradle/libs.versions.toml`.

## When something goes wrong

**A slice failed to build, a licence was refused, or a test failed.** Nothing was uploaded; the
publish guard refuses a payload missing a platform. Fix on `main`, delete the tag on the web UI
(repository → Tags → ⋯), push: the next run re-tags the fixed commit. **A staged deployment is
wrong:** Drop it on the Portal, free. **A published version is wrong:** it stays; release the next
fourth component.

## Secrets

The same four as limn-toolkit: `MAVEN_CENTRAL_USERNAME`, `MAVEN_CENTRAL_PASSWORD` (Portal user
token), `SIGNING_KEY`, `SIGNING_PASSWORD`. Workstation copies live outside every repository.
