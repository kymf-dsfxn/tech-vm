# Capability: multi-company build

One guest builds code for three owners: Q-Free (`gh-qf/`), Tieto (`gh-tb/`, for its Tieto Banktech unit) and Disfixian (`gh-dsfxn/`). Each company has its own artifact repository manager and its own author identity. The guest selects both by directory tree, so a build or a commit under a company tree uses that company's settings with no step by the person running it.

Tieto was formerly EDB and then Tietoevry. The old names remain in identifiers such as `com.edb.finance`, `com.evry.micos` and the `tietoevryfs` GitHub organisation, and this design leaves them unchanged.

This document began as a design note on xd00-lde-0020 on 2026-11-03. Recipe 2.5.0 moved it into the image.

## The problem

Maven reads one user settings file by default, `~/.m2/settings.xml`, so whichever company is configured there wins for every build on the machine. The image used to ship the Q-Free file, which mirrors every repository to `nexus.q-free.com` with `<mirrorOf>*</mirrorOf>`. A `*` mirror takes every request, Maven Central included. On a network where that host does not resolve, every build fails, for both companies:

```text
$ cd gh-tb/parent-pom && mvn verify
Downloading from qf-nexus: https://nexus.q-free.com/content/groups/public/io/github/git-commit-id/...
[ERROR] ... from/to qf-nexus (https://nexus.q-free.com/content/groups/public): nexus.q-free.com: Name or service not known
```

Git has the same shape of fault. One `user.email` in `~/.gitconfig` signs every commit, whichever company owns the repository.

## Maven: a neutral default and a context per tree

The default settings stay neutral, and each company gets its own settings file and its own local repository. A `.envrc` at the top of each company tree sets `MAVEN_ARGS`, and direnv loads it when the shell enters the tree.

The separate local repository matters as much as the separate settings file. Maven 3.9 records in `_remote.repositories` the repository id each cached artifact came from. With one local repository shared between different mirror ids, a cached artifact can be refused with "was cached from a remote repository, but is not available in the current build context". Separate local repositories also keep each company's internal artifacts away from the other company, which client contracts usually expect.

The company CI already works this way. `gh-tb/parent-pom/.github/workflows/build.yaml` writes the `SETTINGS_XML` secret to a file and runs `mvn -s temp-settings.xml`.

| File | Source | Purpose |
| --- | --- | --- |
| `~/.m2/settings.xml` | `payload/extra_cfg/settings.xml`, 0644 | Neutral default. No mirror, so a build outside a company tree uses Maven Central and `~/.m2/repository` |
| `~/.m2/settings-tieto.xml` | `payload/extra_cfg/settings-tieto.xml`, 0600 | Local repository `~/.m2/repo-tieto`. Mirrors everything to the Artifactory `maven-common` virtual repository |
| `~/.m2/settings-qfree.xml` | `payload/extra_cfg/settings-qfree.xml`, 0600 | Local repository `~/.m2/repo-qfree`. Mirrors everything to the Q-Free Nexus |
| `gh-tb/.envrc` | the share | `export MAVEN_ARGS="-s $HOME/.m2/settings-tieto.xml"` |
| `gh-qf/.envrc` | the share | `export MAVEN_ARGS="-s $HOME/.m2/settings-qfree.xml"` |

`guest-install.sh` installs the three settings files. The company files are 0600 because a deploy adds credentials to them. The `.envrc` files live in the share and replicate like any other file.

## direnv: hook and trust

`direnv` is in `packages.list`. `guest-install.sh` appends a guarded hook to `/etc/bash.bashrc`:

```bash
command -v direnv >/dev/null 2>&1 && eval "$(direnv hook bash)"
```

The hook is in `/etc/bash.bashrc` and not in `profile.d`, because `profile.d` runs for login shells only and the hook must run in every interactive shell.

direnv runs an `.envrc` only after `direnv allow`, and keeps that allow record on each node, keyed on the file's path and content. In a replicated share that fails in a predictable way: an edit on one node revokes the allow on every other node until someone runs `direnv allow` there. So the home overlay ships `~/.config/direnv/direnv.toml` with a whitelist of the two exact paths:

```toml
[whitelist]
exact = [
  "/srv/dsfxn/share/10.dev/10.repos/gh-qf/.envrc",
  "/srv/dsfxn/share/10.dev/10.repos/gh-tb/.envrc",
]
```

The cost is stated plainly: a peer that edits one of these files runs code on every node. That is the trust level the share already has, because it holds scripts the named user runs. Keep the list to exact paths, never a prefix.

The order of the parts matters on a node set up by hand. direnv alone makes things worse: `MAVEN_ARGS` then names a settings file that does not exist, and Maven stops with "settings file does not exist". The image installs all the parts together.

## Git: identity per tree

`/etc/gitconfig` includes one identity file per company tree, and refuses to invent one anywhere else:

```ini
[user]
	useConfigOnly = true
[includeIf "gitdir:/srv/dsfxn/share/10.dev/10.repos/gh-qf/"]
	path = ~/.config/git/identity-qf.inc
```

| Tree | Include file (home overlay) | Author |
| --- | --- | --- |
| `gh-qf/` | `~/.config/git/identity-qf.inc` | `Kym Farrell <Kym.Farrell@q-free.com>` |
| `gh-tb/` | `~/.config/git/identity-tb.inc` | `Kym Farrell <Kym.Farrell@tieto.com>` |
| `gh-dsfxn/` | `~/.config/git/identity-dsfxn.inc` | `Kym Farrell <Kym.Farrell@disfixian.com>` |

The trailing `/` in each `gitdir:` pattern matches every repository below the tree. `useConfigOnly` stops git building an identity from the host name, so a commit in a repository outside the three trees fails with "Author identity unknown" until that repository sets its own. That failure is the intent: a wrong identity in a pushed commit cannot be withdrawn, and a refused commit costs one command.

Git needs no shell hook for this, so the identity also applies in VS Code and every other tool that runs git.

A `user.email` in `~/.gitconfig` overrides the includes, because the global file is read after the system file. Keep identity out of `~/.gitconfig`.

## IDEs

An IDE does not inherit the direnv environment. VS Code server processes and IDE Maven runs do not see `MAVEN_ARGS`. Two answers:

- Install the `mkhl.direnv` extension. It loads the nearest `.envrc` into VS Code, so the Maven extensions see `MAVEN_ARGS`. This is the recommended answer on a guest with the Java and Maven extensions.
- Or set the settings file per workspace in `.vscode/settings.json`: `"maven.settingsFile"` (Maven for Java) and `"java.configuration.maven.userSettings"` (Language Support for Java). In IntelliJ IDEA: Settings > Build, Execution, Deployment > Build Tools > Maven, with "User settings file" and "Local repository" overridden.

## Tieto Artifactory

`settings-tieto.xml` sends every request through one mirror, `https://artifactory.finods.com/artifactory/maven-common`. `maven-common` is an Artifactory virtual repository: it serves Tieto-internal artifacts such as `com.evry.micos:parent-pom` and proxies Maven Central. On 2026-11-03 it served both without credentials, so resolution needs no `<servers>` entry.

A `mirrorOf *` mirror sends every download through one Artifactory, which caches and audits it. If a project declares a repository that `maven-common` does not proxy, that project fails to resolve. Change `<mirrorOf>` to `*,!<repo-id>` to let that repository through.

Deployment needs credentials. The commented `<servers>` block in `~/.m2/settings-tieto.xml` shows the form. The server ids `artifactory-release` and `artifactory-snapshot` must match `distributionManagement` in `parent-pom`. Use your own account and an Artifactory access token from the environment (`${env.ARTIFACTORY_TOKEN}`), never the account password and never another team's service account. Never put a filled-in file in the share or in the payload: both replicate. In practice the Micos release workflow deploys from CI, so a local `<servers>` block is rarely needed.

## Network limits

`nexus.q-free.com` does not resolve from every network the guests use. On such a network a Q-Free build fails at resolution until the network changes. That is a limit of the network, not of this design. `artifactory.finods.com` resolves from the networks seen so far.

## Points to know

`MAVEN_ARGS` needs Maven 3.9.0 or later. The image ships 3.9.16. The Maven wrapper (`mvnw`) honours it when the wrapped Maven is 3.9 or later.

Maven expands `${user.home}` in `<localRepository>`, but not `~`.

direnv uses only the nearest `.envrc`. A repository inside `gh-tb/` that needs its own `.envrc` starts it with `source_up`, so it keeps the company context. That file is not whitelisted, so it needs `direnv allow` on each node.

Do not put a personal `-s` path in a project's `.mvn/maven.config`. That file is committed and shared with the team.

An error that names `https://repo.maven.apache.org/maven2` for a `com.evry.micos` artifact means the build ran with the neutral default, usually because direnv did not load. The default context also caches the failure in `~/.m2/repository` ("This failure was cached in the local repository"). The company context uses its own local repository, so the cached failure has no effect there. Delete `~/.m2/repository/com/evry` to clear it.

A `FileNotFoundException` for `.git/.probe-*` after BUILD SUCCESS comes from JGit in `git-commit-id-maven-plugin`. JGit measures the filesystem timestamp resolution in a background thread and saves the result in `~/.config/jgit/config`. A short build exits first, so JGit measures again on every build. The build result is correct. `jgit-measure.sh` in `wd.tb_build/maven-setup/` completes and saves the measurement once. The saved key contains the Java version, so run it again after a JDK update.

To check the active context, run `echo $MAVEN_ARGS` in a repository. For full detail, run `mvn -X validate | grep -E 'user settings|local repository|mirror'`.

## Adding a company

1. Add `payload/extra_cfg/settings-<company>.xml` with its mirror and a new `<localRepository>`, and add it to the Maven stanza in `guest-install.sh` at 0600.
2. Add an `.envrc` at the top of that company's tree, and its exact path to `payload/extra_home/.config/direnv/direnv.toml`.
3. Add `payload/extra_home/.config/git/identity-<company>.inc` and its `includeIf` stanza to `payload/extra_cfg/gitconfig`.

## Stronger isolation

Maven and git are two of several tools that leak between company contexts. The npm registry, the pip index, SSH keys and cloud credentials leak the same way. If a client requires full separation, use a separate OS user account or a dev container for each company. Each then has its own home directory and its own copy of every tool configuration.

## Verification

On 2026-11-03, on xd00-lde-0020, with the Tieto context and an empty `~/.m2/repo-tieto`, `mvn verify` in `gh-tb/parent-pom` downloaded all 62 artifacts from `maven-common` and finished with BUILD SUCCESS. `mvn -N validate` in `gh-tb/micos-database` resolved `com.evry.micos:parent-pom:26.9.12` from `maven-common`. A debug run with the Q-Free context read `settings-qfree.xml`, used `~/.m2/repo-qfree`, and routed Central through the `qf-nexus` mirror.

On a rebuilt guest, check:

```bash
cd /srv/dsfxn/share/10.dev/10.repos/gh-tb && echo "$MAVEN_ARGS"   # -s /home/kymf/.m2/settings-tieto.xml
git -C /srv/dsfxn/share/10.dev/10.repos/gh-dsfxn/tech-vm config user.email   # Kym.Farrell@disfixian.com
```
