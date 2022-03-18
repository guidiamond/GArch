#!/bin/bash

# Install packages
function install_yay_deps() {
    filename='./yay_deps.txt'
    files=$(tr '\n' ' ' < $filename)
    yay -S $files --needed
}


function setup_dotenv() {
    cd ..
    stow "dotfiles"
}

function is_app_not_installed() {
    app_name=$1
    expr $(expr length "$(which $app_name 2>/dev/null)") == 0
}

function setup_yay() {
    is_git_not_installed=$(is_app_not_installed 'git')
    is_yay_not_installed=$(is_app_not_installed 'yay')

    # If yay is already installed, skip
    if [ $is_yay_not_installed = 0 ] ; then
        return
    fi

    # Installs git if not already installed
    if [ $is_git_not_installed = 1 ] ; then
        sudo pacman -S git
    fi

    # Installs yay (Following the steps from: https://www.tecmint.com/install-yay-aur-helper-in-arch-linux-and-manjaro/)
    cd /opt
    sudo git clone https://aur.archlinux.org/yay-git.git
    user=$(whoami)
    group=$(groups | cut -d " " -f1)
    sudo chown -R user:group ./yay-git
    cd yay
    makepkg -si
}

function setup_vim() {
    sh -c 'curl -fLo "${XDG_DATA_HOME:-$HOME/.local/share}"/nvim/site/autoload/plug.vim --create-dirs \
        https://raw.githubusercontent.com/junegunn/vim-plug/master/plug.vim'
}


setup_yay
install_yay_deps
setup_vim
setup_dotenv
