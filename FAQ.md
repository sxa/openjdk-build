# openjdk-build FAQ

This document covers cover how to perform various repeatable tasks in the
repository that might not otherwise be obvious from just looking at the
repository.

## Access control in this repository

The GitHub teams relevant to this repository are as follows (Note, you
won't necessarily have access to see these links):

- [GetOpenJDK](https://github.com/orgs/AdoptOpenJDK/teams/getopenjdk) - `Triage` level of access which lets you assign issues to people
- [build](https://github.com/orgs/AdoptOpenJDK/teams/build) - `Write` access which lets you approve and merge PRs and run and configure most Jenkins jobs
- [release](https://github.com/orgs/AdoptOpenJDK/teams/build) - Allows you to run the release jobs in Jenkins

## How do I find my way around AdoptOpenJDK's build automation scripts?

I wrote this diagram partially for my own benefit in [issue 957](https://github.com/AdoptOpenJDK/openjdk-build/issues/957) that lists the shell scripts (`S`) and environment scripts (`E`). I think it would be useful to incorporate this into the documentation (potentially annotated with a bit more info) so people can find their way around the myriad of script levels that we now have.
Note that the "end-user" scripts start at `makejdk-any-platform.sh` and a
diagram of those relationships can be seen [here](https://github.com/AdoptOpenJDK/openjdk-build/blob/master/docs/images/AdoptOpenJDK_Build_Script_Relationships.png)

*See the [ci-jenkins-pipelines FAQ.md](https://github.com/AdoptOpenJDK/ci-jenkins-pipelines/blob/master/FAQ.md#how-do-i-find-my-way-around-adoptopenjdks-build-automation-scripts) for the Jenkins side of the pipeline*

```markdown
G               - make-adopt-build-farm.sh
S                 - set-platform-specific-configurations.sh
E                    - sbin/common/constants.sh (DUPLICATED LATER FROM configureBuild.sh)
E                    - platform-specific-configurations/${OPERATING_SYSTEM}.sh
S                 - makejdk-any-platform.sh
E                   - ${SCRIPT_DIR}/sbin/common/config_init.sh (Parse options)
E                   - ${SCRIPT_DIR}/docker-build.sh (Runs build.sh within container)
E                   - ${SCRIPT_DIR}/native-build.sh (Runs build.sh natively)
E                   - ${SCRIPT_DIR}/configureBuild.sh
E                     - ${SCRIPT_DIR}/sbin/common/constants.sh
E                     - ${SCRIPT_DIR}/sbin/common/common.sh
E                     - ${SCRIPT_DIR}/signalhandler.sh (rm container on SIGINT/SIGTERM)
S                   - {buildOpenJDKViaDocker|buildOpenJDKInNativeEnvironment}
```

There is also some documentation in [CHANGELOG.md](CHANGELOG.md)

## What are the prerequisites for a system used for builds?

- The upstream OpenJDK build requirements are at [Supported Build Platforms](https://wiki.openjdk.java.net/display/Build/Supported+Build+Platforms)
- The AdoptOpenJDK levels we build on are in [Minimum-OS-levels](https://github.com/AdoptOpenJDK/openjdk-build/wiki/%5BWIP%5D-Minimum-OS-levels) although anything with comparable equivalent or later C libraries should work ok (in particular we have built on most current Linux distros without issues)

In terms of compilers, these are what we currently use for each release:

| Version | OS      | Compiler |
|---------|---------|----------|
| JDK8    | Linux   | GCC 4.8 (HotSpot) GCC 7.6 (OpenJ9)                |
| JDK11+  | Linux   | GCC 7.5                                           |
| JDK8    | Windows | VS2013 (12.0) (HotSpot) or VS2010 (10.0) (OpenJ9) |
| JDK11+  | Windows | VS2017                                            |
| JDK8/11 | AIX     | xlC/C++ 13.1.3                                    |
| JDK13+  | AIX     | xlC/C++ 16.1.0                                    |
| JDK8    | macos   | GCC 4.2.1 (LLVM 2336.11.00                        |
| JDK11   | macos   | clang-700.1.81                                    |
| JDK13+  | macos   | clang-900.0.39.2                                  |

All machines at AdoptOpenJDK are set up using the ansible playbooks from the
[infrastructure](https://github.com/adoptopenjdk/openjdk-infrastructure) repository.

## How do I change the parameters, such as configure flags, for a Jenkins build

Where you change them depends on the scope of the parameter or flag:

- *If the parameter will affect all users, regardless of environment or OS/Arch*
  - [build.sh](https://github.com/AdoptOpenJDK/openjdk-build/blob/master/sbin/build.sh) OR [makejdk-any-platform.sh](https://github.com/AdoptOpenJDK/openjdk-build/blob/master/makejdk-any-platform.sh) depending on how high up in the execution stack it needs to be.
  - [Example PR - Adding a new archival feature for OpenJ9 memory dumps](https://github.com/AdoptOpenJDK/openjdk-build/pull/2464)
- *If the parameter will affect all machines of a specific OS OR related to the environment set up by [our ansible scripts](https://github.com/AdoptOpenJDK/openjdk-infrastructure) at the shell script level*
  - Modify the relevant environment files in [platform-specific-configurations](https://github.com/AdoptOpenJDK/openjdk-build/tree/master/build-farm/platform-specific-configurations)
  - [Example PR - Adding a new configure flag for OpenJ9 on all AIX machines](https://github.com/AdoptOpenJDK/openjdk-build/pull/1442/files)
- *If the parameter will affect only our jenkins environment or jenkins machine environment*
  - Modify the [pipeline files](https://github.com/AdoptOpenJDK/ci-jenkins-pipelines/tree/master/pipelines/build), although this is normally only done for configuration differences such as OpenJ9 Large Heap builds. See [the configuration file documentation](https://github.com/AdoptOpenJDK/ci-jenkins-pipelines#configuration-files) for more information about adding or altering custom jenkins param.
  - [Example PR - Adding Jenkins Support for a Cross Compiled Bisheng Binary](https://github.com/AdoptOpenJDK/ci-jenkins-pipelines/pull/68)

### TL;DR (Quick Reference Table)

| Parameter Location | Impact |
| --- | --- |
| [build.sh](https://github.com/AdoptOpenJDK/openjdk-build/blob/master/sbin/build.sh) OR [makejdk-any-platform.sh](https://github.com/AdoptOpenJDK/openjdk-build/blob/master/makejdk-any-platform.sh) | Anyone (including end users) who are running [makejdk-any-platform.sh](https://github.com/AdoptOpenJDK/openjdk-build/blob/master/makejdk-any-platform.sh) |
| [platform-specific-configurations](https://github.com/AdoptOpenJDK/openjdk-build/tree/master/build-farm/platform-specific-configurations) scripts | Those using [build-farm/make-adopt-build-farm.sh](https://github.com/AdoptOpenJDK/openjdk-build/blob/master/build-farm/make-adopt-build-farm.sh) (inc. our pipelines) - should be stuff specific to our machines |
| Jenkins resources in [ci-jenkins-pipelines](https://github.com/AdoptOpenJDK/ci-jenkins-pipelines) | Only when run through our jenkins pipelines. See the [configuration file documentation](https://github.com/AdoptOpenJDK/ci-jenkins-pipelines#configuration-files) for more information |

## How do the AdoptOpenJDK builds differ from upstream OpenJDK?

We try to build code that is as close to the upstream OpenJDK codebase as
possible. Occastionally we need to apply minor patches on top to solve
specific problems. In general we will attempt to upstream patches to the
OpenJDK project wherever practical to avoid having to hold the changes.

The patches are applies as part of the git mirroring processes in the
[mirror-scripts](https://github.com/adoptium/mirror-scripts/blob/master/jdk8u/buildRepo.sh)
repository and we will usually patch in the `dev` branch leaving `master`
as a clean mirror of the upstream code. The branch which we build from is
defined in `setBranch()` in
[config_init.sh](https://github.com/AdoptOpenJDK/openjdk-build/blob/master/sbin/common/config_init.sh#L345)
in this repository.

We also add the appropriate `configure` options to identify the build as
ours and provide the appropriate support URLs for the variants which we
build (See `configureVersionStringParameter` in
[build.sh](https://github.com/AdoptOpenJDK/openjdk-build/blob/master/sbin/build.sh#L196).

## How to do a new release build

Since the process for this is quite long, this is covered in a separate [RELEASING.md](RELEASING.md) document

## I've modified the build scripts - how can I test my changes?

If you're making changes ensure you follow the contribution guidelines in
[CONTRIBUTING.md](CONTRIBUTING.md) including running [shellcheck](https://github.com/koalaman/shellcheck) if you're modifying the shell scripts.

For more information, see the [PR testing documentation](Testing.md).

## Which OS levels do we build on?

The operating systems/distributions which we build or are documented in the
[openjdk-build wiki](https://github.com/AdoptOpenJDK/openjdk-build/wiki/%5BWIP%5D-Minimum-OS-levels).
Runtime platforms are in our [supported platforms page](https://adoptopenjdk.net/supported_platforms.html).

## How to add a new build pipeline param and associated job configuration?

[This PR](https://github.com/AdoptOpenJDK/openjdk-build/pull/2416) demonstrates changes required to add a new build pipeline param and the associated version/platform job configurations for setting the value when needed  (note, the `pipelines/` dir has since been moved to our [jenkins repository](https://github.com/AdoptOpenJDK/ci-jenkins-pipelines)).
