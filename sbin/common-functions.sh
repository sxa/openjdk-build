#!/bin/bash
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#      http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

# Common functions to be used in scripts

ALSA_LIB_VERSION=${ALSA_LIB_VERSION:-1.0.27.2}
FREETYPE_FONT_SHARED_OBJECT_FILENAME=libfreetype.so.6.5.0
FREETYPE_FONT_VERSION=${FREETYPE_FONT_VERSION:-2.4.0}
FREEMARKER_LIB_VERSION=${FREEMARKER_LIB_VERSION:-2.3.8}

determineBuildProperties() {
    JVM_VARIANT=${JVM_VARIANT:-server}

    BUILD_TYPE=normal
    DEFAULT_BUILD_FULL_NAME=${OS_KERNEL_NAME}-${OS_MACHINE_NAME}-${BUILD_TYPE}-${JVM_VARIANT}-release
    export BUILD_FULL_NAME=${BUILD_FULL_NAME:-"$DEFAULT_BUILD_FULL_NAME"}
}

# ALSA first for sound
checkingAndDownloadingAlsa()
{
  echo "Checking for ALSA"

  FOUND_ALSA=$(find "${WORKING_DIR}" -name "alsa-lib-${ALSA_LIB_VERSION}")

  if [[ ! -z "$FOUND_ALSA" ]] ; then
    echo "Skipping ALSA download"
  else
    wget -nc ftp://ftp.alsa-project.org/pub/lib/alsa-lib-"${ALSA_LIB_VERSION}".tar.bz2
    if [[ ${OS_KERNEL_NAME} == "aix" ]] ; then
      bzip2 -d alsa-lib-"${ALSA_LIB_VERSION}".tar.bz2
      tar xf alsa-lib-"${ALSA_LIB_VERSION}".tar
      rm alsa-lib-"${ALSA_LIB_VERSION}".tar
    else
      tar xf alsa-lib-"${ALSA_LIB_VERSION}".tar.bz2
      rm alsa-lib-"${ALSA_LIB_VERSION}".tar.bz2
    fi
  fi
}

# Freemarker for OpenJ9
checkingAndDownloadingFreemarker()
{
  echo "Checking for FREEMARKER"

  FOUND_FREEMARKER=$(find "${WORKING_DIR}" -type d -name "freemarker-${FREEMARKER_LIB_VERSION}")

  if [[ ! -z "$FOUND_FREEMARKER" ]] ; then
    echo "Skipping FREEMARKER download"
  else
    # wget --no-check-certificate "https://sourceforge.net/projects/freemarker/files/freemarker/${FREEMARKER_LIB_VERSION}/freemarker-${FREEMARKER_LIB_VERSION}.tar.gz/download" -O "freemarker-${FREEMARKER_LIB_VERSION}.tar.gz"
    # Temp fix as sourceforge is broken
    wget --no-check-certificate https://ci.adoptopenjdk.net/userContent/freemarker-2.3.8.tar.gz
    tar -xzf "freemarker-${FREEMARKER_LIB_VERSION}.tar.gz"
    rm "freemarker-${FREEMARKER_LIB_VERSION}.tar.gz"
  fi
}

checkingAndDownloadingFreeType()
{
  echo "Checking for freetype $WORKING_DIR $OPENJDK_REPO_NAME "

  FOUND_FREETYPE=$(find "$WORKING_DIR/$OPENJDK_REPO_NAME/installedfreetype/lib" -name "${FREETYPE_FONT_SHARED_OBJECT_FILENAME}")

  if [[ ! -z "$FOUND_FREETYPE" ]] ; then
    echo "Skipping FreeType download"
  else
    # Then FreeType for fonts: make it and use
    wget -nc http://ftp.acc.umu.se/mirror/gnu.org/savannah/freetype/freetype-"$FREETYPE_FONT_VERSION".tar.gz
    if [[ ${OS_KERNEL_NAME} == "aix" ]] ; then
      gunzip xf freetype-"$FREETYPE_FONT_VERSION".tar.gz
      tar xf freetype-"$FREETYPE_FONT_VERSION".tar
      rm freetype-"$FREETYPE_FONT_VERSION".tar
      MAKE=gmake
    else
      tar xf freetype-"$FREETYPE_FONT_VERSION".tar.gz
      rm freetype-"$FREETYPE_FONT_VERSION".tar.gz
      MAKE=make
    fi

    cd freetype-"$FREETYPE_FONT_VERSION" || exit

    # We get the files we need at $WORKING_DIR/installedfreetype
    # shellcheck disable=SC2046
    if ! (bash ./configure --prefix="${WORKING_DIR}"/"${OPENJDK_REPO_NAME}"/installedfreetype "${FREETYPE_FONT_BUILD_TYPE_PARAM}" && $MAKE all && $MAKE install); then
      # shellcheck disable=SC2154
      echo "${error}Failed to configure and build libfreetype, exiting"
      exit;
    else
      # shellcheck disable=SC2154
      echo "${good}Successfully configured OpenJDK with the FreeType library (libfreetype)!"

     if [[ ${OS_KERNEL_NAME} == "darwin" ]] ; then
        TARGET_DYNAMIC_LIB_DIR="${WORKING_DIR}"/"${OPENJDK_REPO_NAME}"/installedfreetype/lib/
        TARGET_DYNAMIC_LIB="${TARGET_DYNAMIC_LIB_DIR}"/libfreetype.6.dylib
        echo ""
        echo "Listing the contents of ${TARGET_DYNAMIC_LIB_DIR} to see if the dynamic library 'libfreetype.6.dylib' has been created..."
        ls "${TARGET_DYNAMIC_LIB_DIR}"

        echo ""
        echo "Releasing the runpath dependency of the dynamic library ${TARGET_DYNAMIC_LIB}"
        set -x
        install_name_tool -id @rpath/libfreetype.6.dylib "${TARGET_DYNAMIC_LIB}"
        set +x

        # shellcheck disable=SC2181
        if [[ $? == 0 ]]; then
          echo "Successfully released the runpath dependency of the dynamic library ${TARGET_DYNAMIC_LIB}"
        else
          echo "Failed to release the runpath dependency of the dynamic library ${TARGET_DYNAMIC_LIB}"
        fi
      fi
    fi
    # shellcheck disable=SC2154
    echo "${normal}"
  fi
}

checkingAndDownloadCaCerts()
{
  cd "$WORKING_DIR" || exit

  echo "Retrieving cacerts file"

  # Ensure it's the latest we pull in
  rm -rf "${WORKING_DIR}/cacerts_area"

  git clone https://github.com/AdoptOpenJDK/openjdk-build.git cacerts_area
  echo "cacerts should be here..."

  # shellcheck disable=SC2046
  if ! [ -r "${WORKING_DIR}/cacerts_area/security/cacerts" ]; then
    echo "Failed to retrieve the cacerts file, exiting..."
    exit;
  else
    echo "${good}Successfully retrieved the cacerts file!"
  fi
}

downloadingRequiredDependencies()
{
  if [[ "$OSTYPE" == "cygwin" ]] || [[ "$OSTYPE" == "msys" ]] ; then
     echo "Windows or Windows-like environment detected, skipping downloading of dependencies...: Alsa and Freetype."
  else
     echo "Downloading required dependencies...: Alsa, Freetype, Freemarker, and CaCerts."
     time (
        echo "Checking and download Alsa dependency"
        checkingAndDownloadingAlsa
     )

     if [[ -z "${FREETYPE}" ]] ; then
       if [[ -z "$FREETYPE_DIRECTORY" ]]; then
          time (
            echo "Checking and download FreeType Font dependency"
            checkingAndDownloadingFreeType
          )
       else
           echo ""
           echo "---> Skipping the process of checking and downloading the FreeType Font dependency, a pre-built version provided at $FREETYPE_DIRECTORY <---"
           echo ""
       fi
     else
        echo "Skipping Freetype"
     fi
     if [[ "$BUILD_VARIANT" == "openj9" ]]; then
        time (
           echo "Checking and download Freemarker dependency"
           checkingAndDownloadingFreemarker
        )
     fi
  fi
     time (
        echo "Checking and download CaCerts dependency"
        checkingAndDownloadCaCerts
     )
}

getFirstTagFromOpenJDKGitRepo()
{
    git fetch --tags "${GIT_CLONE_ARGUMENTS[@]}"
    justOneFromTheRevList=$(git rev-list --tags --max-count=1)
    tagNameFromRepo=$(git describe --tags "$justOneFromTheRevList")
    echo "$tagNameFromRepo"
}
