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

echo "Common defs"

# shellcheck disable=SC1091
source import-common.sh

[ ! -d hg ] && mkdir -p hg/jdk10 && cd hg/jdk10 && git hg clone "http://hg.openjdk.java.net/jdk10/jdk10"
cd $WORKSPACE

echo "Enter hg"

cd hg || exit 1

# shellcheck disable=SC2035
bpaths=${1:-$(ls -d -1 */*)}     # maintain backward compatibility

for bpath in $bpaths
do
    bpathAsArray=(${bpath/\// })       # for e.g. jdk10/jdk10 or jdk/jdk or openjfx/jfx-dev/rt, becomes:
    hg_root_forest=${bpathAsArray[0]}  #          jdk10 or jdk or openjfx
    hg_repo=${bpathAsArray[1]}         #          jdk10 or jdk or jfx-dev/rt

    pushd "$hg_root_forest/$hg_repo/root"
    echo "Update $hg_root_forest/$hg_repo -> (root)"
    git hg fetch "http://hg.openjdk.java.net/$hg_root_forest/$hg_repo"
    git hg pull "http://hg.openjdk.java.net/$hg_root_forest/$hg_repo"
    popd

    echo "Exit hg"
    echo "Enter combined"

    cd ../combined || exit 1

    echo "Check out master"

    git checkout master || exit 1

    echo "Fetch (root)"

    git fetch "imports/$hg_root_forest/$hg_repo/root" || exit 1

    echo "Merge (root)"

    git merge "imports/$hg_root_forest/$hg_repo/root/master" -m "Merge from (root)" --no-ff || exit 1

#    echo "Push"
     echo "Not pushing ... Check $PWD on `hostname`"
#    git push github master --tags

    cd ../hg || exit 1
done
