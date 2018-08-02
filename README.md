# Repository for code and instructions for building OpenJDK

[![Build Status](https://travis-ci.org/AdoptOpenJDK/openjdk-build.svg?branch=master)](https://travis-ci.org/AdoptOpenJDK/openjdk-build) [![Slack](https://slackin-jmnmplfpdu.now.sh/badge.svg)](https://slackin-jmnmplfpdu.now.sh/)

AdoptOpenJDK makes use of these scripts to build binaries on the build farm at http://ci.adoptopenjdk.net which produces OpenJDK binaries for consumption via 
https://www.adoptopenjdk.net and https://api.adoptopenjdk.net

## Repository contents

This repository contains several useful scripts in order to build OpenJDK personally or at build farm scale.

1. The `docker` folder contains a Docker file which can be used to create a Docker container for building OpenJDK
2. The `git-hg` folder contains scripts to clone an OpenJDK  mercurial forest into a GitHub repo and regularly update it
3. The `mercurial-tags/java-tool` folder contains scripts for TODO
4. The `pipelines` folder contains the Groovy pipeline scripts for Jenkins (e.g. build | test | checksum |release)
5. The `sbin` folder contains the scripts called by the main script.
6. The `security` folder contains a script and `cacerts` file that is bundled with the JDK and used when building OpenJDK: the `cacerts` file is an important 
file that's used to enable SSL connections

The main script to build OpenJDK is `makejdk-any-platform.sh`

## Building OpenJDK

### Building on the Build Farm

In order to build an OpenJDK variant on the build farm you need to follow the 
[Adding-a-new-build-variant](https://github.com/AdoptOpenJDK/TSC/wiki/Adding-a-new-build-variant) instructions.

### Building locally via Docker

**WARN: As of 23rd March 2018 these instructions do not work, there are several issues that need resolving**

Make sure you have started your Docker Daemon first!  For help with getting docker follow the instructions [here](https://docs.docker.com/engine/installation/). 
Once you have Docker started you can then use the script below to build OpenJDK.

```
Usage: ./makejdk-any-platform.sh --version [version] [options]


Versions:
  jdk8u  - https://github.com/AdoptOpenJDK/openjdk-jdk8u
  jdk9u  - https://github.com/AdoptOpenJDK/openjdk-jdk9u
  jdk10u - https://github.com/AdoptOpenJDK/openjdk-jdk10u
  jdk11  - https://github.com/AdoptOpenJDK/openjdk-jdk11

Options:
  -s,   --source <path>              specify the location for the source and dependencies to be cloned, defaults to ./openjdk. If it is specified, docker is not used
  -d,   --destination <path>         specify the location for the tarball (eg. /path/ or /path/here.tar.gz)
  -r,   --repository <repo>          specify a custom repository (eg. username/openjdk-jdk8u)
  -b,   --branch <branch>            specify a custom branch (eg. dev)
  -k,   --keep                       reuse docker container (prevents deleting)
  -j,   --jtreg                      run jtreg after building
  -js,  --jtreg-subsets              select one or more jtreg tests to run
  -S,   --ssh                        use ssh when cloning git
  -sf   --skip-freetype              skip building freetype
  -nc   --no-colour                  disable colour output
  -ftd  --freetype-dir               specify the location of an existing FreeType library that can be used for the OpenJDK build process
  -dsgc --disable-shallow-git-clone  disable shallow cloning of git repo(s) using the --depth=1 CLI option
  -bv   --variant <name>             specify a build variant name, e.g. openj9
  -c    --clean-docker-build         clean docker data volume
  -t    --tag <tag>                  specify a custom tag
  --sign <path>                      specify the location for the windows p12 certificate. Used only for windows builds to sign DLL
  -ca   --configure-args <args>      specify a custom configuration arguments
```

The simplest way to build OpenJDK using our scripts is to run `makejdk-any-platform.sh` and have your user be in the Docker group on the machine 
(or prefix all of your Docker commands with `sudo`). This script will create a Docker container that will be configured with all of the required 
dependencies and a base operating system in order to build OpenJDK. For example:

`./makejdk-any-platform.sh -c --ssh --version jdk8u`

* **NOTE:** If you don't use SSH keys (if you do then pass `-ssh`) to connect to GitHub then the script will challenge you for your GitHub username and password.
* **NOTE:** The script will clone source code into the `--source` directory (defaults to `openjdk`).
* **NOTE:** By default the docker container is removed each time and your build will be copied from the container to the host. 
To override this behaviour, specify the `-k` or `--keep` option.
* **NOTE:** The entire process will take some time, especially if you have not saved the Docker image from a previous run. 
* **NOTE:** If you set the `-d` option it will pass that through to `makejdk.sh`, the resulting zipped tarball will be copied to the value for -d, for example:
`makejdk.sh /target/directory` will result in the JDK being built inside of your Docker container and then copied to `/target/directory` on the host

#### Configuring Docker for non sudo use

To use the Docker commands without using the sudo prefix, you will need to be in the Docker group which can be achieved with the following three commands 
(performed as `root`)

1. `sudo groupadd docker`: creates the Docker group if it doesn't already exist
2. `sudo gpasswd -a yourusernamehere docker`: adds a user to the Docker group
3. `sudo service docker restart`: restarts the Docker service so the above changes can take effect

### Building in your local environment

Please note that your build host will need to have certain pre-requisites met.  We provide Ansible scripts in the 
[openjdk-infrastructure](https://www.github.com/AdoptOpenJDK/openjdk-infrastructure) project for setting these pre-requisites.

You can use the `makejdk-any-platform.sh` script by providing two parameters: 

1. The _working directory_ (which is where files will be downloaded to: this includes a number of libraries used with OpenJDK itself such as FreeType and ALSA)
1. The _target directory_ which will be used to store the final _.tar.gz_ file containing the _j2sdk-image_

e.g `./makejdk-any-platform.sh -s /path/to/workspace -d /target/directory`

**NOTE:** Usage can be found via `makejdk-any-platform.sh --help`, the exact usage is available for this script as well.

### None of the above?

You can use the `makejdk.sh` script by providing two parameters:

1. The _working directory_ (which is where files will be downloaded to: this includes a number of libraries used with OpenJDK itself such as FreeType and ALSA)
1. The _target directory_ which will be used to store the final _.tar.gz_ file containing the _j2sdk-image_

e.g `./makejdk.sh -s /path/to/workspace -d /target/directory`

