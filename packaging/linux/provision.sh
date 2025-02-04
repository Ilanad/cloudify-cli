#!/bin/bash

set -e -x

export GITHUB_USERNAME=$1
export GITHUB_TOKEN=$2
export AWS_ACCESS_KEY_ID=$3
export AWS_ACCESS_KEY=$4
export REPO=$5
export BRANCH=$6

# These env vars are being updated by the bump version process
export CORE_TAG_NAME="6.2.0.dev1"
export CORE_BRANCH="master"

# Linux Preperation
function prepare_linux () {
    sudo chmod 777 /opt
    if  which yum >> /dev/null; then
        sudo yum install -y http://opensource.wandisco.com/centos/6/git/x86_64/wandisco-git-release-6-1.noarch.rpm
        sudo yum install -y git fakeroot python-devel rpm-build
        sudo yum update -y nss
        gpg=gpg2
    else
        sudo apt-get install -y git curl fakeroot python-dev dirmngr
        gpg=gpg
    fi

    curl -sSL https://rvm.io/pkuczynski.asc | $gpg --import -
    $gpg --keyserver hkp://pool.sks-keyservers.net --recv-keys \
        409B6B1796C275462A1703113804BB82D39DC0E3 \
        7D2BAF1CF37B13E2069D6956105BD0E739499BDB
    curl -sSL https://get.rvm.io | bash -s stable

    if  which yum >> /dev/null; then
        source /etc/profile.d/rvm.sh
    else
        source $HOME/.rvm/scripts/rvm
    fi
    rvm install 2.4.4 && rvm use 2.4.4
    gem install bundler -v '=1.16.0' --no-document
    gem install mixlib-cli -v 1.7.0 --no-document
    gem install ohai -v 14.8.12 --no-document
    gem install omnibus -v 6.0.25 --no-document
}

echo "BRANCH=$BRANCH"
echo "REPO=$REPO"
prepare_linux


set +x

curl -u ${GITHUB_USERNAME}:${GITHUB_TOKEN} https://raw.githubusercontent.com/cloudify-cosmo/${REPO}/${CORE_BRANCH}/packages-urls/common_build_env.sh -o ./common_build_env.sh &&
source common_build_env.sh &&

curl https://raw.githubusercontent.com/cloudify-cosmo/cloudify-common/${CORE_BRANCH}/packaging/common/provision.sh -o ./common-provision.sh &&
source common-provision.sh

set -x

install_common_prereqs &
rm -rf cloudify-cli
git clone https://github.com/cloudify-cosmo/cloudify-cli.git
cd ~/cloudify-cli/packaging/omnibus
export CLI_BRANCH="$CORE_BRANCH"
if [[ "$CORE_BRANCH" != "master" ]]; then
    if [[ "$REPO" == "cloudify-versions" ]]; then
        source ~/cloudify-cli/packaging/source_branch
    fi
    git checkout -b $CLI_BRANCH origin/$CLI_BRANCH
else
    git checkout $CLI_BRANCH
fi

if [[ ! -z $BRANCH ]] && [[ "$BRANCH" != "master" ]] && git show-ref --quiet origin/$BRANCH ; then
    export CLI_BRANCH="$BRANCH"
    git checkout $CLI_BRANCH
    AWS_S3_PATH="$AWS_S3_PATH/$BRANCH"
fi

# Get Omnibus software from Chef Omnibus repo
git clone https://github.com/chef/omnibus-software.git
pushd omnibus-software
    git checkout 1b2dfe467cbc22e0e2e232e2648af3482830bfd7
popd
list_of_omnibus_softwares="gdbm cacerts config_guess gdbm libffi makedepend
    ncurses openssl pkg-config-lite setuptools
    util-macros version-manifest xproto zlib"
for omnibus_softwate in $list_of_omnibus_softwares
do
    if [[ -e omnibus-software/config/software/$omnibus_softwate.rb ]] ; then
        cp -r omnibus-software/config/software/$omnibus_softwate.rb \
        config/software/$omnibus_softwate.rb
    else
        echo "Missing software in Omnibus-Software repo"
        exit
    fi

    [[ -e omnibus-software/config/patches/$omnibus_softwate ]] &&
    cp -r omnibus-software/config/patches/$omnibus_softwate config/patches/
done

[ ! -d config/templates/ ] && mkdir config/templates/
cp -r omnibus-software/config/templates/* config/templates/
curl https://raw.githubusercontent.com/chef/omnibus-software/master/config/software/preparation.rb -o config/software/preparation.rb
curl https://raw.githubusercontent.com/systemizer/omnibus-software/master/config/software/pip.rb -o config/software/pip.rb

if [[ "$OSTYPE" == "darwin"* ]]; then
    grep -l '/opt' config/software/* | xargs sed -i "" 's|/opt|/usr/local/opt|g'
fi

omnibus build cloudify && result="success"
cd pkg
cat *.json || exit 1
rm -f version-manifest.json
[ $(ls | grep rpm | sed -n 2p ) ] && FILEEXT="rpm"
[ $(ls | grep deb | sed -n 2p ) ] && FILEEXT="deb"
[ $(ls | grep pkg | sed -n 2p ) ] && FILEEXT="pkg"

#remove the -1 - omnibus set the build_iteration to 1 if it null
file=$(basename $(find . -type f -name "*.$FILEEXT"))
echo "file=$file"
file_no_build=$(echo "$file" | sed 's/\(.*\)-1/\1/' | sed 's/cloudify/cloudify-cli/')
echo "file_no_build=$file_no_build"
mv $file $file_no_build

[ "$result" == "success" ] && create_md5 $FILEEXT &&
[ -z ${AWS_ACCESS_KEY} ] || upload_to_s3 $FILEEXT && upload_to_s3 "md5" &&
upload_to_s3 "json"
