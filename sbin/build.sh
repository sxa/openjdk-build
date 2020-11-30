#!/bin/bash

################################################################################
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#      https://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
################################################################################

################################################################################
#
# Build OpenJDK - can be called directly but is typically called by
# docker-build.sh or native-build.sh.
#
# See bottom of the script for the call order and each function for further
# details.
#
# Calls 'configure' then 'make' in order to build OpenJDK
#
################################################################################

set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=sbin/prepareWorkspace.sh
source "$SCRIPT_DIR/prepareWorkspace.sh"

# shellcheck source=sbin/common/config_init.sh
source "$SCRIPT_DIR/common/config_init.sh"

# shellcheck source=sbin/common/constants.sh
source "$SCRIPT_DIR/common/constants.sh"

# shellcheck source=sbin/common/common.sh
source "$SCRIPT_DIR/common/common.sh"

export LIB_DIR=$(crossPlatformRealPath "${SCRIPT_DIR}/../pipelines/")

export jreTargetPath
export CONFIGURE_ARGS=""
export ADDITIONAL_MAKE_TARGETS=""
export GIT_CLONE_ARGUMENTS=()

# Parse the CL arguments, defers to the shared function in common-functions.sh
function parseArguments() {
  parseConfigurationArguments "$@"
}

# Add an argument to the configure call
addConfigureArg() {
  # Only add an arg if it is not overridden by a user-specified arg.
  if [[ ${BUILD_CONFIG[CONFIGURE_ARGS_FOR_ANY_PLATFORM]} != *"$1"* ]] && [[ ${BUILD_CONFIG[USER_SUPPLIED_CONFIGURE_ARGS]} != *"$1"* ]]; then
    CONFIGURE_ARGS="${CONFIGURE_ARGS} ${1}${2}"
  fi
}

# Add an argument to the configure call (if it's not empty)
addConfigureArgIfValueIsNotEmpty() {
  # Only try to add an arg if the second argument is not empty.
  if [ ! -z "$2" ]; then
    addConfigureArg "$1" "$2"
  fi
}

# Configure the boot JDK
configureBootJDKConfigureParameter() {
  addConfigureArgIfValueIsNotEmpty "--with-boot-jdk=" "${BUILD_CONFIG[JDK_BOOT_DIR]}"
}

# Shenandaoh was backported to Java 11 as of 11.0.9 but requires this build
# parameter to ensure its inclusion. For Java 12+ this is automatically set
configureShenandoahBuildParameter() {
  if [ "${BUILD_CONFIG[BUILD_VARIANT]}" == "${BUILD_VARIANT_HOTSPOT}" ] && [ "${BUILD_CONFIG[OPENJDK_CORE_VERSION]}" == "${JDK11_CORE_VERSION}" ]; then
      addConfigureArg "--with-jvm-features=" "shenandoahgc"
  fi
}

# Configure the boot JDK
configureMacOSCodesignParameter() {
  if [ ! -z "${BUILD_CONFIG[MACOSX_CODESIGN_IDENTITY]}" ]; then
    # This command needs to escape the double quotes because they are needed to preserve the spaces in the codesign cert name
    addConfigureArg "--with-macosx-codesign-identity=" "\"${BUILD_CONFIG[MACOSX_CODESIGN_IDENTITY]}\""
  fi
}

# Get the OpenJDK update version and build version
getOpenJDKUpdateAndBuildVersion() {
  cd "${BUILD_CONFIG[WORKSPACE_DIR]}/${BUILD_CONFIG[WORKING_DIR]}"

  if [ -d "${BUILD_CONFIG[OPENJDK_SOURCE_DIR]}/.git" ]; then

    # It does exist and it's a repo other than the AdoptOpenJDK one
    cd "${BUILD_CONFIG[OPENJDK_SOURCE_DIR]}" || return

    if [ -f ".git/shallow.lock" ]; then
      echo "Detected lock file, assuming this is an error, removing"
      rm ".git/shallow.lock"
    fi

    # shellcheck disable=SC2154
    echo "Pulling latest tags and getting the latest update version using git fetch -q --tags ${BUILD_CONFIG[SHALLOW_CLONE_OPTION]}"
    # shellcheck disable=SC2154
    echo "NOTE: This can take quite some time!  Please be patient"
    git fetch -q --tags ${BUILD_CONFIG[SHALLOW_CLONE_OPTION]}
    local openJdkVersion=$(getOpenJdkVersion)
    if [[ "${openJdkVersion}" == "" ]]; then
      # shellcheck disable=SC2154
      echo "Unable to detect git tag, exiting..."
      exit 1
    else
      echo "OpenJDK repo tag is $openJdkVersion"
    fi

    local openjdk_update_version
    openjdk_update_version=$(echo "${openJdkVersion}" | cut -d'u' -f 2 | cut -d'-' -f 1)

    # TODO dont modify config in build script
    echo "Version: ${openjdk_update_version} ${BUILD_CONFIG[OPENJDK_BUILD_NUMBER]}"
  fi

  cd "${BUILD_CONFIG[WORKSPACE_DIR]}"
}

getOpenJdkVersion() {
  local version

  if [ "${BUILD_CONFIG[BUILD_VARIANT]}" == "${BUILD_VARIANT_CORRETTO}" ]; then
    local corrVerFile=${BUILD_CONFIG[WORKSPACE_DIR]}/${BUILD_CONFIG[WORKING_DIR]}/${BUILD_CONFIG[OPENJDK_SOURCE_DIR]}/version.txt

    local corrVersion="$(cut -d'.' -f 1 <${corrVerFile})"

    if [ "${corrVersion}" == "8" ]; then
      local updateNum="$(cut -d'.' -f 2 <${corrVerFile})"
      local buildNum="$(cut -d'.' -f 3 <${corrVerFile})"
      local fixNum="$(cut -d'.' -f 4 <${corrVerFile})"
      version="jdk8u${updateNum}-b${buildNum}.${fixNum}"
    else
      local minorNum="$(cut -d'.' -f 2 <${corrVerFile})"
      local updateNum="$(cut -d'.' -f 3 <${corrVerFile})"
      local buildNum="$(cut -d'.' -f 4 <${corrVerFile})"
      local fixNum="$(cut -d'.' -f 5 <${corrVerFile})"
      version="jdk-${corrVersion}.${minorNum}.${updateNum}+${buildNum}.${fixNum}"
    fi
  else
    version=${BUILD_CONFIG[TAG]:-$(getFirstTagFromOpenJDKGitRepo)}
    if [ "${BUILD_CONFIG[BUILD_VARIANT]}" == "${BUILD_VARIANT_DRAGONWELL}" ]; then
      version=$(echo $version | cut -d'_' -f 2)
    fi
    # TODO remove pending #1016
    version=${version%_adopt}
    version=${version#aarch64-shenandoah-}
  fi

  echo ${version}
}

# Ensure that we produce builds with versions strings something like:
#
# openjdk version "1.8.0_131"
# OpenJDK Runtime Environment (build 1.8.0-adoptopenjdk-<user>_2017_04_17_17_21-b00)
# OpenJDK 64-Bit Server VM (build 25.71-b00, mixed mode)
configureVersionStringParameter() {
  stepIntoTheWorkingDirectory

  local openJdkVersion=$(getOpenJdkVersion)
  echo "OpenJDK repo tag is ${openJdkVersion}"

  # --with-milestone=fcs deprecated at jdk12+ and not used for jdk11- (we use --without-version-pre/opt)
  if [ "${BUILD_CONFIG[OPENJDK_FEATURE_NUMBER]}" == 8 ] && [ "${BUILD_CONFIG[RELEASE]}" == "true" ]; then
    addConfigureArg "--with-milestone=" "fcs"
  fi

  local dateSuffix=$(date -u +%Y%m%d%H%M)

  # Configures "vendor" jdk properties.
  # AdoptOpenJDK default values are set after this code block
  # TODO 1. We should probably look at having these values passed through a config
  # file as opposed to hardcoding in shell
  # TODO 2. This highlights us conflating variant with vendor. e.g. OpenJ9 is really
  # a technical variant with Eclipse as the vendor
  if [[ "${BUILD_CONFIG[BUILD_VARIANT]}" == "${BUILD_VARIANT_DRAGONWELL}" ]]; then
    BUILD_CONFIG[VENDOR]="Alibaba"
    BUILD_CONFIG[VENDOR_VERSION]="\"(Alibaba Dragonwell)\""
    BUILD_CONFIG[VENDOR_URL]="http://www.alibabagroup.com"
    BUILD_CONFIG[VENDOR_BUG_URL]="mailto:dragonwell_use@googlegroups.com"
    BUILD_CONFIG[VENDOR_VM_BUG_URL]="mailto:dragonwell_use@googlegroups.com"
  elif [[ "${BUILD_CONFIG[BUILD_VARIANT]}" == "${BUILD_VARIANT_OPENJ9}" ]]; then
    BUILD_CONFIG[VENDOR_VM_BUG_URL]="https://github.com/eclipse/openj9/issues"
  fi

  addConfigureArg "--with-vendor-name=" "${BUILD_CONFIG[VENDOR]:-"AdoptOpenJDK"}"
  addConfigureArg "--with-vendor-url=" "${BUILD_CONFIG[VENDOR_URL]:-"https://adoptopenjdk.net/"}"
  addConfigureArg "--with-vendor-bug-url=" "${BUILD_CONFIG[VENDOR_BUG_URL]:-"https://github.com/AdoptOpenJDK/openjdk-support/issues"}"
  addConfigureArg "--with-vendor-vm-bug-url=" "${BUILD_CONFIG[VENDOR_VM_BUG_URL]:-"https://github.com/AdoptOpenJDK/openjdk-support/issues"}"
  if [ "${BUILD_CONFIG[OPENJDK_FEATURE_NUMBER]}" -gt 8 ]; then
    addConfigureArg "--with-vendor-version-string=" "${BUILD_CONFIG[VENDOR_VERSION]:-"AdoptOpenJDK"}"
  fi

  if [ "${BUILD_CONFIG[OPENJDK_CORE_VERSION]}" == "${JDK8_CORE_VERSION}" ]; then

    if [ "${BUILD_CONFIG[RELEASE]}" == "false" ]; then
      addConfigureArg "--with-user-release-suffix=" "${dateSuffix}"
    fi

    if [ "${BUILD_CONFIG[BUILD_VARIANT]}" == "${BUILD_VARIANT_HOTSPOT}" ]; then

      # No JFR support in AIX or zero builds (s390 or armv7l)
      if [ "${BUILD_CONFIG[OS_ARCHITECTURE]}" != "s390x" ] && [ "${BUILD_CONFIG[OS_KERNEL_NAME]}" != "aix" ] && [ "${BUILD_CONFIG[OS_ARCHITECTURE]}" != "armv7l" ]; then
        addConfigureArg "--enable-jfr" ""
      fi

    fi

    # Set the update version (e.g. 131), this gets passed in from the calling script
    local updateNumber=${BUILD_CONFIG[OPENJDK_UPDATE_VERSION]}
    if [ -z "${updateNumber}" ]; then
      updateNumber=$(echo "${openJdkVersion}" | cut -f1 -d"-" | cut -f2 -d"u")
    fi
    addConfigureArgIfValueIsNotEmpty "--with-update-version=" "${updateNumber}"

    # Set the build number (e.g. b04), this gets passed in from the calling script
    local buildNumber=${BUILD_CONFIG[OPENJDK_BUILD_NUMBER]}
    if [ -z "${buildNumber}" ]; then
      buildNumber=$(echo "${openJdkVersion}" | cut -f2 -d"-")
    fi

    if [ "${buildNumber}" ] && [ "${buildNumber}" != "ga" ]; then
      addConfigureArgIfValueIsNotEmpty "--with-build-number=" "${buildNumber}"
    fi
  elif [ "${BUILD_CONFIG[OPENJDK_CORE_VERSION]}" == "${JDK9_CORE_VERSION}" ]; then
    local buildNumber=${BUILD_CONFIG[OPENJDK_BUILD_NUMBER]}
    if [ -z "${buildNumber}" ]; then
      buildNumber=$(echo "${openJdkVersion}" | cut -f2 -d"+")
    fi

    if [ "${BUILD_CONFIG[RELEASE]}" == "false" ]; then
      addConfigureArg "--with-version-opt=" "${dateSuffix}"
    else
      addConfigureArg "--without-version-opt" ""
    fi

    addConfigureArg "--without-version-pre" ""
    addConfigureArgIfValueIsNotEmpty "--with-version-build=" "${buildNumber}"
  else
    # > JDK 9

    # Set the build number (e.g. b04), this gets passed in from the calling script
    local buildNumber=${BUILD_CONFIG[OPENJDK_BUILD_NUMBER]}
    if [ -z "${buildNumber}" ]; then
      # Get build number (eg.10) from tag of potential format "jdk-11.0.4+10_adopt"
      buildNumber=$(echo "${openJdkVersion}" | cut -d_ -f1 | cut -f2 -d"+")
    fi

    if [ "${BUILD_CONFIG[RELEASE]}" == "false" ]; then
      addConfigureArg "--with-version-opt=" "${dateSuffix}"
    else
      addConfigureArg "--without-version-opt" ""
    fi

    addConfigureArg "--without-version-pre" ""
    addConfigureArgIfValueIsNotEmpty "--with-version-build=" "${buildNumber}"
  fi
  echo "Completed configuring the version string parameter, config args are now: ${CONFIGURE_ARGS}"
}

# Construct all of the 'configure' parameters
buildingTheRestOfTheConfigParameters() {
  if [ ! -z "$(which ccache)" ]; then
    addConfigureArg "--enable-ccache" ""
  fi

  # Point-in-time dependency for openj9 only
  if [[ "${BUILD_CONFIG[BUILD_VARIANT]}" == "${BUILD_VARIANT_OPENJ9}" ]]; then
    addConfigureArg "--with-freemarker-jar=" "${BUILD_CONFIG[WORKSPACE_DIR]}/${BUILD_CONFIG[WORKING_DIR]}/freemarker-${FREEMARKER_LIB_VERSION}/freemarker.jar"
  fi

  if [ "${BUILD_CONFIG[OPENJDK_CORE_VERSION]}" == "${JDK8_CORE_VERSION}" ]; then
    addConfigureArg "--with-x=" "/usr/include/X11"
    addConfigureArg "--with-alsa=" "${BUILD_CONFIG[WORKSPACE_DIR]}/${BUILD_CONFIG[WORKING_DIR]}/installedalsa"
  fi
}

configureDebugParameters() {
  # We don't want any extra debug symbols - ensure it's set to release;
  # other options include fastdebug and slowdebug.
  addConfigureArg "--with-debug-level=" "release"

  # If debug symbols package is requested, generate them separately
  if [ ${BUILD_CONFIG[CREATE_DEBUG_SYMBOLS_PACKAGE]} == true ]; then
    addConfigureArg "--with-native-debug-symbols=" "external"
  else
    if [ "${BUILD_CONFIG[OPENJDK_CORE_VERSION]}" == "${JDK8_CORE_VERSION}" ]; then
      addConfigureArg "--disable-zip-debug-info" ""
      if [[ "${BUILD_CONFIG[BUILD_VARIANT]}" != "${BUILD_VARIANT_OPENJ9}" ]]; then
        addConfigureArg "--disable-debug-symbols" ""
      fi
    else
      if [[ "${BUILD_CONFIG[BUILD_VARIANT]}" != "${BUILD_VARIANT_OPENJ9}" ]]; then
        addConfigureArg "--with-native-debug-symbols=" "none"
      fi
    fi
  fi
}

configureFreetypeLocation() {
  if [[ ! "${CONFIGURE_ARGS}" =~ "--with-freetype" ]]; then
    if [[ "${BUILD_CONFIG[FREETYPE]}" == "true" ]]; then
      if [[ "$OSTYPE" == "cygwin" ]] || [[ "$OSTYPE" == "msys" ]]; then
        case "${BUILD_CONFIG[OPENJDK_CORE_VERSION]}" in
        jdk8* | jdk9* | jdk10*) addConfigureArg "--with-freetype-src=" "${BUILD_CONFIG[WORKSPACE_DIR]}/libs/freetype" ;;
        *) freetypeDir=${BUILD_CONFIG[FREETYPE_DIRECTORY]:-bundled} ;;
        esac
      else
        local freetypeDir=BUILD_CONFIG[FREETYPE_DIRECTORY]
        case "${BUILD_CONFIG[OPENJDK_CORE_VERSION]}" in
        jdk8* | jdk9* | jdk10*) freetypeDir=${BUILD_CONFIG[FREETYPE_DIRECTORY]:-"${BUILD_CONFIG[WORKSPACE_DIR]}/${BUILD_CONFIG[WORKING_DIR]}/installedfreetype"} ;;
        *) freetypeDir=${BUILD_CONFIG[FREETYPE_DIRECTORY]:-bundled} ;;
        esac

        echo "setting freetype dir to ${freetypeDir}"
        addConfigureArg "--with-freetype=" "${freetypeDir}"
      fi
    fi
  fi
}

# Configure the command parameters
configureCommandParameters() {
  configureVersionStringParameter
  configureBootJDKConfigureParameter
  configureShenandoahBuildParameter
  configureMacOSCodesignParameter
  configureDebugParameters

  if [[ "$OSTYPE" == "cygwin" ]] || [[ "$OSTYPE" == "msys" ]]; then
    echo "Windows or Windows-like environment detected, skipping configuring environment for custom Boot JDK and other 'configure' settings."

    if [[ "${BUILD_CONFIG[BUILD_VARIANT]}" == "${BUILD_VARIANT_OPENJ9}" ]] && [ "${BUILD_CONFIG[OPENJDK_CORE_VERSION]}" == "${JDK8_CORE_VERSION}" ]; then
      local addsDir="${BUILD_CONFIG[WORKSPACE_DIR]}/${BUILD_CONFIG[WORKING_DIR]}/${BUILD_CONFIG[OPENJDK_SOURCE_DIR]}/closed/adds"

      # This is unfortunately required as if the path does not start with "/cygdrive" the make scripts are unable to find the "/closed/adds" directory.
      if ! echo "$addsDir" | egrep -q "^/cygdrive/"; then
        # BUILD_CONFIG[WORKSPACE_DIR] does not seem to be an absolute path, prepend /cygdrive/c/cygwin64/"
        echo "Prepending /cygdrive/c/cygwin64/ to BUILD_CONFIG[WORKSPACE_DIR]"
        addsDir="/cygdrive/c/cygwin64/$addsDir"
      fi

      echo "adding source route -with-add-source-root=${addsDir}"
      addConfigureArg "--with-add-source-root=" "${addsDir}"
    fi
  else
    echo "Building up the configure command..."
    buildingTheRestOfTheConfigParameters
  fi

  echo "Configuring jvm variants if provided"
  addConfigureArgIfValueIsNotEmpty "--with-jvm-variants=" "${BUILD_CONFIG[JVM_VARIANT]}"

  # Now we add any platform-specific args after the configure args, so they can override if necessary.
  CONFIGURE_ARGS="${CONFIGURE_ARGS} ${BUILD_CONFIG[CONFIGURE_ARGS_FOR_ANY_PLATFORM]}"

  # Finally, we add any configure arguments the user has specified on the command line.
  # This is done last, to ensure the user can override any args they need to.
  CONFIGURE_ARGS="${CONFIGURE_ARGS} ${BUILD_CONFIG[USER_SUPPLIED_CONFIGURE_ARGS]}"

  configureFreetypeLocation

  echo "Completed configuring the version string parameter, config args are now: ${CONFIGURE_ARGS}"
}

# Make sure we're in the source directory for OpenJDK now
stepIntoTheWorkingDirectory() {
  cd "${BUILD_CONFIG[WORKSPACE_DIR]}/${BUILD_CONFIG[WORKING_DIR]}/${BUILD_CONFIG[OPENJDK_SOURCE_DIR]}" || exit

  # corretto nest their source under /src in their dir
  if [ "${BUILD_CONFIG[BUILD_VARIANT]}" == "${BUILD_VARIANT_CORRETTO}" ]; then
    cd "src"
  fi

  echo "Should have the source, I'm at $PWD"
}

buildTemplatedFile() {
  echo "Configuring command and using the pre-built config params..."

  stepIntoTheWorkingDirectory

  echo "Currently at '${PWD}'"

  FULL_CONFIGURE="bash ./configure --verbose ${CONFIGURE_ARGS}"
  echo "Running ./configure with arguments '${FULL_CONFIGURE}'"

  # If it's Java 9+ then we also make test-image to build the native test libraries,
  # For openj9 add debug-image
  JDK_PREFIX="jdk"
  JDK_VERSION_NUMBER="${BUILD_CONFIG[OPENJDK_FEATURE_NUMBER]}"
  if [[ "${BUILD_CONFIG[BUILD_VARIANT]}" == "${BUILD_VARIANT_OPENJ9}" ]]; then
    ADDITIONAL_MAKE_TARGETS=" test-image debug-image"
  elif [ "$JDK_VERSION_NUMBER" -gt 8 ] || [ "${BUILD_CONFIG[OPENJDK_CORE_VERSION]}" == "${JDKHEAD_VERSION}" ]; then
    ADDITIONAL_MAKE_TARGETS=" test-image"
  fi

  if [[ "${BUILD_CONFIG[MAKE_EXPLODED]}" == "true" ]]; then
    # In order to make an exploded image we cannot have any additional targets
    ADDITIONAL_MAKE_TARGETS=""
  fi

  FULL_MAKE_COMMAND="${BUILD_CONFIG[MAKE_COMMAND_NAME]} ${BUILD_CONFIG[MAKE_ARGS_FOR_ANY_PLATFORM]} ${BUILD_CONFIG[USER_SUPPLIED_MAKE_ARGS]} ${ADDITIONAL_MAKE_TARGETS}"

  # shellcheck disable=SC2002
  cat "$SCRIPT_DIR/build.template" |
    sed -e "s|{configureArg}|${FULL_CONFIGURE}|" \
      -e "s|{makeCommandArg}|${FULL_MAKE_COMMAND}|" >"${BUILD_CONFIG[WORKSPACE_DIR]}/config/configure-and-build.sh"
}

executeTemplatedFile() {
  stepIntoTheWorkingDirectory

  echo "Currently at '${PWD}'"

  # Execute the build passing the workspace dir and target dir as params for configure.txt
  bash "${BUILD_CONFIG[WORKSPACE_DIR]}/config/configure-and-build.sh" ${BUILD_CONFIG[WORKSPACE_DIR]} ${BUILD_CONFIG[TARGET_DIR]}
  exitCode=$?

  if [ "${exitCode}" -eq 1 ]; then
    echo "Failed to make the JDK, exiting"
    exit 1
  elif [ "${exitCode}" -eq 2 ]; then
    echo "Failed to configure the JDK, exiting"
    echo "Did you set the JDK boot directory correctly? Override by exporting JDK_BOOT_DIR"
    echo "For example, on RHEL you would do export JDK_BOOT_DIR=/usr/lib/jvm/java-1.7.0-openjdk-1.7.0.131-2.6.9.0.el7_3.x86_64"
    echo "Current JDK_BOOT_DIR value: ${BUILD_CONFIG[JDK_BOOT_DIR]}"
    exit 2
  fi

}

getGradleJavaHome() {
  local gradleJavaHome=""

  if [ ${JAVA_HOME+x} ] && [ -d "${JAVA_HOME}" ]; then
    gradleJavaHome=${JAVA_HOME}
  fi

  if [ ${JDK8_BOOT_DIR+x} ] && [ -d "${JDK8_BOOT_DIR}" ]; then
    gradleJavaHome=${JDK8_BOOT_DIR}
  fi

  # Special case arm because for some unknown reason the JDK11_BOOT_DIR that arm downloads is unable to form connection
  # to services.gradle.org
  if [ ${JDK11_BOOT_DIR+x} ] && [ -d "${JDK11_BOOT_DIR}" ] && [ "${ARCHITECTURE}" != "arm" ]; then
    gradleJavaHome=${JDK11_BOOT_DIR}
  fi

  if [ ! -d "$gradleJavaHome" ]; then
    echo "[WARNING] Unable to find java to run gradle with, this build may fail with /bin/java: No such file or directory. Set JAVA_HOME, JDK8_BOOT_DIR or JDK11_BOOT_DIR to squash this warning: $gradleJavaHome" >&2
  fi

  echo $gradleJavaHome
}

getGradleUserHome() {
  local gradleUserHome=""

  if [ -n "${BUILD_CONFIG[GRADLE_USER_HOME_DIR]}" ]; then
    gradleUserHome="${BUILD_CONFIG[GRADLE_USER_HOME_DIR]}"
  else
    gradleUserHome="${BUILD_CONFIG[WORKSPACE_DIR]}/.gradle"
  fi

  echo $gradleUserHome
}

buildSharedLibs() {
  cd "${LIB_DIR}"

  local gradleJavaHome=$(getGradleJavaHome)
  local gradleUserHome=$(getGradleUserHome)

  echo "Running gradle with $gradleJavaHome at $gradleUserHome"

  gradlecount=1
  while ! JAVA_HOME="$gradleJavaHome" GRADLE_USER_HOME="$gradleUserHome" bash ./gradlew --no-daemon clean shadowJar; do
    echo "RETRYWARNING: Gradle failed on attempt $gradlecount"
    sleep 120s # Wait before retrying in case of network/server outage ...
    gradlecount=$((gradlecount + 1))
    [ $gradlecount -gt 3 ] && exit 1
  done

  # Test that the parser can execute as fail fast rather than waiting till after the build to find out
  "$gradleJavaHome"/bin/java -version 2>&1 | "$gradleJavaHome"/bin/java -cp "target/libs/adopt-shared-lib.jar" ParseVersion -s -f semver 1
}

parseJavaVersionString() {
  ADOPT_BUILD_NUMBER="${ADOPT_BUILD_NUMBER:-1}"

  local javaVersion=$(JAVA_HOME="$PRODUCT_HOME" "$PRODUCT_HOME"/bin/java -version 2>&1)

  cd "${LIB_DIR}"
  local gradleJavaHome=$(getGradleJavaHome)
  local version=$(echo "$javaVersion" | JAVA_HOME="$gradleJavaHome" "$gradleJavaHome"/bin/java -cp "target/libs/adopt-shared-lib.jar" ParseVersion -s -f openjdk-semver $ADOPT_BUILD_NUMBER | tr -d '\n')

  echo $version
}

# Print the version string so we know what we've produced
printJavaVersionString() {
  stepIntoTheWorkingDirectory

  case "${BUILD_CONFIG[OS_KERNEL_NAME]}" in
  "darwin")
    # shellcheck disable=SC2086
    PRODUCT_HOME=$(ls -d ${PWD}/build/*/images/${BUILD_CONFIG[JDK_PATH]}/Contents/Home)
    ;;
  *)
    # shellcheck disable=SC2086
    PRODUCT_HOME=$(ls -d ${PWD}/build/*/images/${BUILD_CONFIG[JDK_PATH]})
    ;;
  esac
  if [[ -d "$PRODUCT_HOME" ]]; then
     echo "'$PRODUCT_HOME' found"
     if [ ! -r "$PRODUCT_HOME/bin/java" ]; then
       echo "===$PRODUCT_HOME===="
       ls -alh "$PRODUCT_HOME"

       echo "===$PRODUCT_HOME/bin/===="
       ls -alh "$PRODUCT_HOME/bin/"

       echo "Error 'java' does not exist in '$PRODUCT_HOME'."
       exit -1
     elif [ "${ARCHITECTURE}" == "riscv64" ]; then
       # riscv is cross compiled, so we cannot run it on the build system
       # This is a temporary plausible solution in the absence of another fix
       local jdkversion=$(getOpenJdkVersion)
       local jdkversionNoPrefix=${jdkversion#jdk-}
       local jdkShortVersion=${jdkversionNoPrefix%%+*}
       cat << EOT > "${BUILD_CONFIG[WORKSPACE_DIR]}/${BUILD_CONFIG[TARGET_DIR]}/metadata/version.txt"
openjdk version "${jdkShortVersion}" "$(date +%Y-%m-%d)"
OpenJDK Runtime Environment AdoptOpenJDK (build ${jdkversionNoPrefix}-$(date +%Y%m%d%H%M))
Eclipse OpenJ9 VM AdoptOpenJDK (build master-000000000, JRE 11 Linux riscv-64-Bit Compressed References $(date +%Y%m%d)_00 (JIT disabled, AOT disabled)
OpenJ9   - 000000000
OMR      - 000000000
JCL      - 000000000 based on ${jdkversion})
EOT
     else
       # print version string around easy to find output
       # do not modify these strings as jenkins looks for them
       echo "=JAVA VERSION OUTPUT="
       "$PRODUCT_HOME"/bin/java -version 2>&1
       echo "=/JAVA VERSION OUTPUT="

       "$PRODUCT_HOME"/bin/java -version > "${BUILD_CONFIG[WORKSPACE_DIR]}/${BUILD_CONFIG[TARGET_DIR]}/metadata/version.txt" 2>&1
     fi
  else
    echo "'$PRODUCT_HOME' does not exist, build might have not been successful or not produced the expected JDK image at this location."
    exit -1
  fi
}

getJdkArchivePath() {
  # Todo: Set this to the outcome of https://github.com/AdoptOpenJDK/openjdk-build/issues/1016
  # local version="$(parseJavaVersionString)
  # echo "jdk-${version}"

  local version=$(getOpenJdkVersion)
  echo "$version"
}

getJreArchivePath() {
  local jdkArchivePath=$(getJdkArchivePath)
  echo "${jdkArchivePath}-jre"
}

getTestImageArchivePath() {
  local jdkArchivePath=$(getJdkArchivePath)
  echo "${jdkArchivePath}-test-image"
}

getDebugImageArchivePath() {
  local jdkArchivePath=$(getJdkArchivePath)
  echo "${jdkArchivePath}-debug-image"
}

getDebugSymbolsArchivePath() {
  local jdkArchivePath=$(getJdkArchivePath)
  echo "${jdkArchivePath}-debug-symbols"
}

# Clean up
removingUnnecessaryFiles() {
  local jdkTargetPath=$(getJdkArchivePath)
  local jreTargetPath=$(getJreArchivePath)
  local testImageTargetPath=$(getTestImageArchivePath)
  local debugImageTargetPath=$(getDebugImageArchivePath)

  echo "Removing unnecessary files now..."

  stepIntoTheWorkingDirectory

  cd build/*/images || return

  echo "Currently at '${PWD}'"

  local jdkPath=$(ls -d ${BUILD_CONFIG[JDK_PATH]})
  echo "moving ${jdkPath} to ${jdkTargetPath}"
  rm -rf "${jdkTargetPath}" || true
  mv "${jdkPath}" "${jdkTargetPath}"

  if [ -d "$(ls -d ${BUILD_CONFIG[JRE_PATH]})" ]; then
    echo "moving $(ls -d ${BUILD_CONFIG[JRE_PATH]}) to ${jreTargetPath}"
    rm -rf "${jreTargetPath}" || true
    mv "$(ls -d ${BUILD_CONFIG[JRE_PATH]})" "${jreTargetPath}"

    case "${BUILD_CONFIG[OS_KERNEL_NAME]}" in
    "darwin") dirToRemove="${jreTargetPath}/Contents/Home" ;;
    *) dirToRemove="${jreTargetPath}" ;;
    esac
    rm -rf "${dirToRemove}"/demo || true
  fi

  # Test image - check if the config is set and directory exists
  local testImagePath="${BUILD_CONFIG[TEST_IMAGE_PATH]}"
  if [ ! -z "${testImagePath}" ] && [ -d "${testImagePath}" ]; then
    echo "moving ${testImagePath} to ${testImageTargetPath}"
    rm -rf "${testImageTargetPath}" || true
    mv "${testImagePath}" "${testImageTargetPath}"
  fi

  # Debug image - check if the config is set and directory exists
  local debugImagePath="${BUILD_CONFIG[DEBUG_IMAGE_PATH]}"
  if [ ! -z "${debugImagePath}" ] && [ -d "${debugImagePath}" ]; then
    echo "moving ${debugImagePath} to ${debugImageTargetPath}"
    rm -rf "${debugImageTargetPath}" || true
    mv "${debugImagePath}" "${debugImageTargetPath}"
  fi

  # Remove files we don't need
  case "${BUILD_CONFIG[OS_KERNEL_NAME]}" in
  "darwin") dirToRemove="${jdkTargetPath}/Contents/Home" ;;
  *) dirToRemove="${jdkTargetPath}" ;;
  esac
  rm -rf "${dirToRemove}"/demo || true

  # In OpenJ9 builds, debug symbols are captured in the debug image:
  # we don't want another copy of them in the main JDK or JRE archives.
  # Builds for other variants don't normally include debug symbols,
  # but if they were explicitly requested via the configure option
  # '--with-native-debug-symbols=(external|zipped)' leave them alone.
  if [[ "${BUILD_CONFIG[BUILD_VARIANT]}" == "${BUILD_VARIANT_OPENJ9}" ]]; then
    deleteDebugSymbols
  fi

  if [ ${BUILD_CONFIG[CREATE_DEBUG_SYMBOLS_PACKAGE]} == true ]; then
    case "${BUILD_CONFIG[OS_KERNEL_NAME]}" in
    *cygwin*)
      # on Windows, we want to take .pdb files
      debugSymbols=$(find "${jdkTargetPath}" -type f -name "*.pdb")
      ;;
    darwin)
      # on MacOSX, we want to take .dSYM folders
      debugSymbols=$(find "${jdkTargetPath}" -print -type d -name "*.dSYM")
      ;;
    *)
      # on other platforms, we want to take .debuginfo files
      debugSymbols=$(find "${jdkTargetPath}" -type f -name "*.debuginfo")
      ;;
    esac

    # if debug symbols were found, copy them to a different folder
    if [ -n "${debugSymbols}" ]; then
      local debugSymbolsTargetPath=$(getDebugSymbolsArchivePath)
      echo "${debugSymbols}" | cpio -pdm ${debugSymbolsTargetPath}
    fi

    deleteDebugSymbols
  fi

  echo "Finished removing unnecessary files from ${jdkTargetPath}"
}

deleteDebugSymbols() {
  # .diz files may be present on any platform
  # Note that on AIX, find does not support the '-delete' option.
  find "${jdkTargetPath}" "${jreTargetPath}" -type f -name "*.diz" | xargs rm -f || true

  case "${BUILD_CONFIG[OS_KERNEL_NAME]}" in
  *cygwin*)
    # on Windows, we want to remove .map and .pdb files
    find "${jdkTargetPath}" "${jreTargetPath}" -type f -name "*.map" -delete || true
    find "${jdkTargetPath}" "${jreTargetPath}" -type f -name "*.pdb" -delete || true
    ;;
  darwin)
    # on MacOSX, we want to remove .dSYM folders
    find "${jdkTargetPath}" "${jreTargetPath}" -type d -name "*.dSYM" | xargs -I "{}" rm -rf "{}"
    ;;
  *)
    # on other platforms, we want to remove .debuginfo files
    find "${jdkTargetPath}" "${jreTargetPath}" -type f -name "*.debuginfo" | xargs rm -f || true
    ;;
  esac
}

moveFreetypeLib() {
  local LIB_DIRECTORY="${1}"

  if [ ! -d "${LIB_DIRECTORY}" ]; then
    echo "Could not find dir: ${LIB_DIRECTORY}"
    return
  fi

  echo " Performing copying of the free font library to ${LIB_DIRECTORY}, applicable for this version of the JDK. "

  local SOURCE_LIB_NAME="${LIB_DIRECTORY}/libfreetype.dylib.6"

  if [ ! -f "${SOURCE_LIB_NAME}" ]; then
    SOURCE_LIB_NAME="${LIB_DIRECTORY}/libfreetype.dylib"
  fi

  if [ ! -f "${SOURCE_LIB_NAME}" ]; then
    echo "[Error] ${SOURCE_LIB_NAME} does not exist in the ${LIB_DIRECTORY} folder, please check if this is the right folder to refer to, aborting copy process..."
    return
  fi

  local TARGET_LIB_NAME="${LIB_DIRECTORY}/libfreetype.6.dylib"

  local INVOKED_BY_FONT_MANAGER="${LIB_DIRECTORY}/libfontmanager.dylib"

  echo "Currently at '${PWD}'"
  echo "Copying ${SOURCE_LIB_NAME} to ${TARGET_LIB_NAME}"
  echo " *** Workaround to fix the MacOSX issue where invocation to ${INVOKED_BY_FONT_MANAGER} fails to find ${TARGET_LIB_NAME} ***"

  # codesign freetype before it is bundled
  if [ ! -z "${BUILD_CONFIG[MACOSX_CODESIGN_IDENTITY]}" ]; then
    # test if codesign certificate is usable
    if touch test && codesign --sign "Developer ID Application: London Jamocha Community CIC" test && rm -rf test; then
      ENTITLEMENTS="$WORKSPACE/entitlements.plist"
      codesign --entitlements "$ENTITLEMENTS" --options runtime --timestamp --sign "${BUILD_CONFIG[MACOSX_CODESIGN_IDENTITY]}" "${SOURCE_LIB_NAME}"
    else
      echo "skipping codesign as certificate cannot be found"
    fi
  fi

  cp "${SOURCE_LIB_NAME}" "${TARGET_LIB_NAME}"
  if [ -f "${INVOKED_BY_FONT_MANAGER}" ]; then
    otool -L "${INVOKED_BY_FONT_MANAGER}"
  else
    # shellcheck disable=SC2154
    echo "[Warning] ${INVOKED_BY_FONT_MANAGER} does not exist in the ${LIB_DIRECTORY} folder, please check if this is the right folder to refer to, this may cause runtime issues, please beware..."
  fi

  otool -L "${TARGET_LIB_NAME}"

  echo "Finished copying ${SOURCE_LIB_NAME} to ${TARGET_LIB_NAME}"
}

# If on a Mac, mac a copy of the font lib as required
makeACopyOfLibFreeFontForMacOSX() {
  local DIRECTORY="${1}"
  local PERFORM_COPYING=$2

  echo "PERFORM_COPYING=${PERFORM_COPYING}"
  if [ "${PERFORM_COPYING}" == "false" ]; then
    echo " Skipping copying of the free font library to ${DIRECTORY}, does not apply for this version of the JDK. "
    return
  fi

  if [[ "${BUILD_CONFIG[OS_KERNEL_NAME]}" == "darwin" ]]; then
    moveFreetypeLib "${DIRECTORY}/Contents/Home/lib"
    moveFreetypeLib "${DIRECTORY}/Contents/Home/jre/lib"
  fi
}

# Get the tags from the git repo and choose the latest chronologically ordered tag for the given JDK version.
#
# Note, we have to chronologically order, as with a Shallow cloned (depth=1) git repo there is no "topo-order"
# for tags, also commit date order cannot be used either as the commit dates do not necessarily follow chronologically.
#
# Excluding "openj9" tag names as they have other ones for milestones etc. that get in the way
getFirstTagFromOpenJDKGitRepo() {
  # JDK8 tag sorting:
  # Tag Format "jdk8uLLL-bBB"
  # cut chars 1-5 => LLL-bBB
  # awk "-b" separator into a single "-" => LLL-BB
  # prefix "-" to allow line numbering stable sorting using nl => -LLL-BB
  # Sort by build level BB first
  # Then do "stable" sort (keeping BB order) by build level LLL
  local jdk8_tag_sort1="sort -t- -k3,3n"
  local jdk8_tag_sort2="sort -t- -k2,2n"
  local jdk8_get_tag_cmd="grep -v _openj9 | grep -v _adopt | cut -c6- | awk -F'[\-b]+' '{print \$1\"-\"\$2}' | sed 's/^/-/' | $jdk8_tag_sort1 | nl | $jdk8_tag_sort2 | cut -f2- | sed 's/^-/jdk8u/' | sed 's/-/-b/' | tail -1"

  # JDK11+ tag sorting:
  # We use sort and tail to choose the latest tag in case more than one refers the same commit.
  # Versions tags are formatted: jdk-V[.W[.X[.P]]]+B; with V, W, X, P, B being numeric.
  # Transform "-" to "." in tag so we can sort as: "jdk.V[.W[.X[.P]]]+B"
  # Transform "+" to ".0.+" during the sort so that .P (patch) is defaulted to "0" for those
  # that don't have one, and the trailing "." to terminate the 5th field from the +
  # First, sort on build number (B):
  local jdk11plus_tag_sort1="sort -t+ -k2,2n"
  # Second, (stable) sort on (V), (W), (X), (P): P(Patch) is optional and defaulted to "0"
  local jdk11plus_tag_sort2="sort -t. -k2,2n -k3,3n -k4,4n -k5,5n"
  jdk11plus_get_tag_cmd="grep -v _openj9 | grep -v _adopt | sed 's/jdk-/jdk./g' | sed 's/+/.0.+/g' | $jdk11plus_tag_sort1 | nl | $jdk11plus_tag_sort2 | sed 's/\.0\.+/+/g' | cut -f2- | sed 's/jdk./jdk-/g' | tail -1"

  # Choose tag search keyword and get cmd based on version
  local TAG_SEARCH="jdk-${BUILD_CONFIG[OPENJDK_FEATURE_NUMBER]}*+*"
  local get_tag_cmd=$jdk11plus_get_tag_cmd
  if [ "${BUILD_CONFIG[OPENJDK_FEATURE_NUMBER]}" == "8" ]; then
    TAG_SEARCH="jdk8u*-b*"
    get_tag_cmd=$jdk8_get_tag_cmd
  fi

  # If openj9 and the closed/openjdk-tag.gmk file exists which specifies what level the openj9 jdk code is based upon...
  # Read OPENJDK_TAG value from that file..
  local openj9_openjdk_tag_file="${BUILD_CONFIG[WORKSPACE_DIR]}/${BUILD_CONFIG[WORKING_DIR]}/${BUILD_CONFIG[OPENJDK_SOURCE_DIR]}/closed/openjdk-tag.gmk"
  if [[ "${BUILD_CONFIG[BUILD_VARIANT]}" == "${BUILD_VARIANT_OPENJ9}" ]] && [[ -f "${openj9_openjdk_tag_file}" ]]; then
    firstMatchingNameFromRepo=$(grep OPENJDK_TAG ${openj9_openjdk_tag_file} | awk 'BEGIN {FS = "[ :=]+"} {print $2}')
  else
    git fetch --tags "${BUILD_CONFIG[WORKSPACE_DIR]}/${BUILD_CONFIG[WORKING_DIR]}/${BUILD_CONFIG[OPENJDK_SOURCE_DIR]}"

    firstMatchingNameFromRepo=$(eval "git tag -l $TAG_SEARCH | $get_tag_cmd")
  fi

  if [ -z "$firstMatchingNameFromRepo" ]; then
    echo "WARNING: Failed to identify latest tag in the repository" 1>&2
  else
    echo "$firstMatchingNameFromRepo"
  fi
}

createArchive() {
  repoLocation=$1
  targetName=$2

  archiveExtension=$(getArchiveExtension)

  createOpenJDKArchive "${repoLocation}" "OpenJDK"
  archive="${PWD}/OpenJDK${archiveExtension}"

  echo "Your final archive was created at ${archive}"

  echo "Moving the artifact to ${BUILD_CONFIG[WORKSPACE_DIR]}/${BUILD_CONFIG[TARGET_DIR]}"
  mv "${archive}" "${BUILD_CONFIG[WORKSPACE_DIR]}/${BUILD_CONFIG[TARGET_DIR]}/${targetName}"
}

# Create a Tar ball
createOpenJDKTarArchive() {
  stepIntoTheWorkingDirectory

  local jdkTargetPath=$(getJdkArchivePath)
  local jreTargetPath=$(getJreArchivePath)
  local testImageTargetPath=$(getTestImageArchivePath)
  local debugImageTargetPath=$(getDebugImageArchivePath)
  local debugSymbolsTargetPath=$(getDebugSymbolsArchivePath)

  echo "OpenJDK JDK path will be ${jdkTargetPath}. JRE path will be ${jreTargetPath}"

  if [ -d "${jreTargetPath}" ]; then
    local jreName=$(echo "${BUILD_CONFIG[TARGET_FILE_NAME]}" | sed 's/-jdk/-jre/')
    createArchive "${jreTargetPath}" "${jreName}"
  fi
  if [ -d "${testImageTargetPath}" ]; then
    echo "OpenJDK test image path will be ${testImageTargetPath}."
    local testImageName=$(echo "${BUILD_CONFIG[TARGET_FILE_NAME]//-jdk/-testimage}")
    createArchive "${testImageTargetPath}" "${testImageName}"
  fi
  if [ -d "${debugImageTargetPath}" ]; then
    echo "OpenJDK debug image path will be ${debugImageTargetPath}."
    local debugImageName=$(echo "${BUILD_CONFIG[TARGET_FILE_NAME]//-jdk/-debugimage}")
    createArchive "${debugImageTargetPath}" "${debugImageName}"
  fi
  if [ -d "${debugSymbolsTargetPath}" ]; then
    echo "OpenJDK debug symbols path will be ${debugSymbolsTargetPath}."
    local debugSymbolsName=$(echo "${BUILD_CONFIG[TARGET_FILE_NAME]//-jdk/-debug-symbols}")
    createArchive "${debugSymbolsTargetPath}" "${debugSymbolsName}"
  fi
  createArchive "${jdkTargetPath}" "${BUILD_CONFIG[TARGET_FILE_NAME]}"
}

# Echo success
showCompletionMessage() {
  echo "All done!"
}

copyFreeFontForMacOS() {
  local jdkTargetPath=$(getJdkArchivePath)
  local jreTargetPath=$(getJreArchivePath)

  makeACopyOfLibFreeFontForMacOSX "${jdkTargetPath}" "${BUILD_CONFIG[COPY_MACOSX_FREE_FONT_LIB_FOR_JDK_FLAG]}"
  makeACopyOfLibFreeFontForMacOSX "${jreTargetPath}" "${BUILD_CONFIG[COPY_MACOSX_FREE_FONT_LIB_FOR_JRE_FLAG]}"
}

wipeOutOldTargetDir() {
  rm -r "${BUILD_CONFIG[WORKSPACE_DIR]:?}/${BUILD_CONFIG[TARGET_DIR]}" || true
}

createTargetDir() {
  # clean out old builds
  mkdir -p "${BUILD_CONFIG[WORKSPACE_DIR]}/${BUILD_CONFIG[TARGET_DIR]}" || exit
  mkdir "${BUILD_CONFIG[WORKSPACE_DIR]}/${BUILD_CONFIG[TARGET_DIR]}/metadata" || exit
  if [ "${BUILD_CONFIG[BUILD_VARIANT]}" == "${BUILD_VARIANT_OPENJ9}" ]; then
    mkdir "${BUILD_CONFIG[WORKSPACE_DIR]}/${BUILD_CONFIG[TARGET_DIR]}/metadata/variant_version" || exit
  fi
}

fixJavaHomeUnderDocker() {
  # If we are inside docker we cannot trust the JDK_BOOT_DIR that was detected on the host system
  if [[ "${BUILD_CONFIG[USE_DOCKER]}" == "true" ]]; then
    # clear BUILD_CONFIG[JDK_BOOT_DIR] and re set it
    BUILD_CONFIG[JDK_BOOT_DIR]=""
    setBootJdk
  fi
}

addInfoToReleaseFile() {
  # Extra information is added to the release file here
  echo "===GENERATING RELEASE FILE==="
  cd $PRODUCT_HOME
  JAVA_LOC="$PRODUCT_HOME/bin/java"
  echo "ADDING IMPLEMENTOR"
  addImplementor
  echo "ADDING BUILD SHA"
  addBuildSHA
  echo "ADDING FULL VER"
  addFullVersion
  echo "ADDING SEM VER"
  addSemVer
  echo "ADDING BUILD OS"
  addBuildOS
  echo "ADDING VARIANT"
  addJVMVariant
  echo "ADDING JVM VERSION"
  addJVMVersion
  # OpenJ9 specific options
  if [ "${BUILD_CONFIG[BUILD_VARIANT]}" == "${BUILD_VARIANT_OPENJ9}" ]; then
    echo "ADDING HEAP SIZE"
    addHeapSize
    echo "ADDING J9 TAG"
    addJ9Tag
  fi
  echo "MIRRORING TO JRE"
  mirrorToJRE
  echo "ADDING IMAGE TYPE"
  addImageType
  echo "===RELEASE FILE GENERATED==="
}

addHeapSize() { # Adds an identifier for heap size on OpenJ9 builds
  local heapSize=""
  if [[ $($JAVA_LOC -version 2>&1 | grep 'Compressed References') ]]; then
    heapSize="Standard"
  else
    heapSize="Large"
  fi
  echo -e HEAP_SIZE=\"$heapSize\" >>release
}

addImplementor() {
  if [ "${BUILD_CONFIG[OPENJDK_CORE_VERSION]}" == "${JDK8_CORE_VERSION}" ]; then
    echo -e IMPLEMENTOR=\"${BUILD_CONFIG[VENDOR]}\" >>release
  fi
}

addJVMVersion() { # Adds the JVM version i.e. openj9-0.21.0
  local jvmVersion=$($JAVA_LOC -XshowSettings:properties -version 2>&1 | grep 'java.vm.version' | sed 's/^.*= //' | tr -d '\r')
  echo -e JVM_VERSION=\"$jvmVersion\" >>release
}

addFullVersion() { # Adds the full version including build number i.e. 11.0.9+5-202009040847
  local fullVer=$($JAVA_LOC -XshowSettings:properties -version 2>&1 | grep 'java.runtime.version' | sed 's/^.*= //' | tr -d '\r')
  echo -e FULL_VERSION=\"$fullVer\" >>release
}

addJVMVariant() {
  echo -e JVM_VARIANT=\"${BUILD_CONFIG[BUILD_VARIANT]^}\" >>release
}

addBuildSHA() { # git SHA of the build repository i.e. openjdk-build
  local buildSHA=$(git -C ${BUILD_CONFIG[WORKSPACE_DIR]} rev-parse --short HEAD 2>/dev/null)
  if [[ $buildSHA ]]; then
    echo -e BUILD_SOURCE=\"git:$buildSHA\" >>release
  else
    echo "Unable to fetch build SHA, does a work tree exist?..."
  fi
}

addBuildOS() {
  local buildOS="Unknown"
  local buildVer="Unknown"
  if [ "${BUILD_CONFIG[OS_KERNEL_NAME]}" == "darwin" ]; then
    buildOS=$(sw_vers | sed -n 's/^ProductName:[[:blank:]]*//p')
    buildVer=$(sw_vers | tail -n 2 | awk '{print $2}')
  elif [ "${BUILD_CONFIG[OS_KERNEL_NAME]}" == "linux" ]; then
    buildOS=$(uname -s)
    buildVer=$(uname -r)
  else # Fall back to java properties OS/Version info
    buildOS=$($JAVA_LOC -XshowSettings:properties -version 2>&1 | grep 'os.name' | sed 's/^.*= //' | tr -d '\r')
    buildVer=$($JAVA_LOC -XshowSettings:properties -version 2>&1 | grep 'os.version' | sed 's/^.*= //' | tr -d '\r')
  fi
  echo -e BUILD_INFO=\"OS: $buildOS Version: $buildVer\" >>release
}

addJ9Tag() {
  # java.vm.version varies or for OpenJ9 depending on if it is a release build i.e. master-*gitSha* or 0.21.0
  # This code makes sure that a version number is always present in the release file i.e. openj9-0.21.0
  local j9Location="${BUILD_CONFIG[WORKSPACE_DIR]}/${BUILD_CONFIG[WORKING_DIR]}/${BUILD_CONFIG[OPENJDK_SOURCE_DIR]}/openj9"
  # Pull the tag associated with the J9 commit being used
  J9_TAG=$(git -C $j9Location describe --abbrev=0)
  if [ ${BUILD_CONFIG[RELEASE]} = false ]; then
    echo -e OPENJ9_TAG=\"$J9_TAG\" >> release
  fi
}

addSemVer() { # Pulls the semantic version from the tag associated with the openjdk repo
  local fullVer=$(getOpenJdkVersion)
  SEM_VER="$fullVer"
  if [ "${BUILD_CONFIG[OPENJDK_CORE_VERSION]}" == "${JDK8_CORE_VERSION}" ]; then
    SEM_VER=$(echo "$semVer" | cut -c4- | awk -F'[-b0]+' '{print $1"+"$2}' | sed 's/u/.0./')
  else
    SEM_VER=$(echo "$SEM_VER" | cut -c5-) # i.e. 11.0.2+12
  fi
  echo -e SEMANTIC_VERSION=\"$SEM_VER\" >> release
}

mirrorToJRE() {
  stepIntoTheWorkingDirectory

  case "${BUILD_CONFIG[OS_KERNEL_NAME]}" in
  "darwin")
    JRE_HOME=$(ls -d ${PWD}/build/*/images/${BUILD_CONFIG[JRE_PATH]}/Contents/Home)
    ;;
  *)
    JRE_HOME=$(ls -d ${PWD}/build/*/images/${BUILD_CONFIG[JRE_PATH]})
    ;;
  esac

  cp -f $PRODUCT_HOME/release $JRE_HOME/release
}

addImageType() {
  echo -e IMAGE_TYPE=\"JDK\" >>$PRODUCT_HOME/release
  echo -e IMAGE_TYPE=\"JRE\" >>$JRE_HOME/release
}

addInfoToJson(){
  mv "${BUILD_CONFIG[WORKSPACE_DIR]}/${BUILD_CONFIG[TARGET_DIR]}/configure.txt" "${BUILD_CONFIG[WORKSPACE_DIR]}/${BUILD_CONFIG[TARGET_DIR]}/metadata/"
  addVariantVersionToJson
  addVendorToJson
  addSourceToJson # Build repository commit SHA
}

addVariantVersionToJson(){
  if [ "${BUILD_CONFIG[BUILD_VARIANT]}" == "${BUILD_VARIANT_OPENJ9}" ]; then  
    local variantJson=$(echo "$J9_TAG" | cut -c8- | tr "-" ".") # i.e. 0.22.0.m2
    local major=$(echo "$variantJson" | awk -F[.] '{print $1}')
    local minor=$(echo "$variantJson" | awk -F[.] '{print $2}')
    local security=$(echo "$variantJson" | awk -F[.] '{print $3}')
    local tags=$(echo "$variantJson" | awk -F[.] '{print $4}')
    if [[ $(echo "$variantJson" | tr -cd '.' | wc -c) -lt 3 ]]; then # Precaution for when OpenJ9 releases a 1.0.0 version
      tags="$minor"
      minor=""
    fi
    echo -n ${major:-"0"} > ${BUILD_CONFIG[WORKSPACE_DIR]}/${BUILD_CONFIG[TARGET_DIR]}/metadata/variant_version/major.txt
    echo -n ${minor:-"0"} > ${BUILD_CONFIG[WORKSPACE_DIR]}/${BUILD_CONFIG[TARGET_DIR]}/metadata/variant_version/minor.txt
    echo -n ${security:-"0"} > ${BUILD_CONFIG[WORKSPACE_DIR]}/${BUILD_CONFIG[TARGET_DIR]}/metadata/variant_version/security.txt
    echo -n ${tags:-""} > ${BUILD_CONFIG[WORKSPACE_DIR]}/${BUILD_CONFIG[TARGET_DIR]}/metadata/variant_version/tags.txt
  fi
}

addVendorToJson(){
  echo -n "${BUILD_CONFIG[VENDOR]}" > ${BUILD_CONFIG[WORKSPACE_DIR]}/${BUILD_CONFIG[TARGET_DIR]}/metadata/vendor.txt
}

addSourceToJson(){ # Pulls the basename of the origin repo, or uses 'openjdk-build' in rare cases of failure
  local repoName=$(basename -s .git $(cd ${BUILD_CONFIG[WORKSPACE_DIR]} && git config --get remote.origin.url 2>/dev/null))
  local buildSHA=$(git -C ${BUILD_CONFIG[WORKSPACE_DIR]} rev-parse --short HEAD 2>/dev/null)
  if [[ $buildSHA ]]; then
    echo -n "${repoName:-"openjdk-build"}/$buildSHA" > ${BUILD_CONFIG[WORKSPACE_DIR]}/${BUILD_CONFIG[TARGET_DIR]}/metadata/buildSource.txt
  else
    echo "Unable to fetch build SHA, does a work tree exist?..."
  fi
}

################################################################################

loadConfigFromFile
fixJavaHomeUnderDocker
cd "${BUILD_CONFIG[WORKSPACE_DIR]}"

parseArguments "$@"

if [[ "${BUILD_CONFIG[ASSEMBLE_EXPLODED_IMAGE]}" == "true" ]]; then
  buildTemplatedFile
  executeTemplatedFile
  removingUnnecessaryFiles
  copyFreeFontForMacOS
  createOpenJDKTarArchive
  showCompletionMessage
  exit 0
fi

# buildSharedLibs

wipeOutOldTargetDir
createTargetDir

configureWorkspace

getOpenJDKUpdateAndBuildVersion
configureCommandParameters
buildTemplatedFile
executeTemplatedFile

if [[ "${BUILD_CONFIG[MAKE_EXPLODED]}" != "true" ]]; then
  printJavaVersionString
  addInfoToReleaseFile
  addInfoToJson
  removingUnnecessaryFiles
  copyFreeFontForMacOS
  createOpenJDKTarArchive
fi

showCompletionMessage

# ccache is not detected properly TODO
# change grep to something like $GREP -e '^1.*' -e '^2.*' -e '^3\.0.*' -e '^3\.1\.[0123]$'`]
# See https://github.com/AdoptOpenJDK/openjdk-jdk8u/blob/dev/common/autoconf/build-performance.m4
