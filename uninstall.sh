#!/bin/bash

## ========================================================================================
##       Title: uninstall.sh
##      Author: R. L. Paxton
##     Version: 4.0
##        Date: 2025-06-19
##     License: Apache 2.0
## Description: Uninstall script for CCAB audiobook converter
##              Removes CCAB from system or user installation
## ========================================================================================

# Colors for output
C0='\033[0;00m'    # Normal
C1='\033[0;92m'    # Green
#shellcheck disable=SC2034
C4='\033[0;93m'    # Yellow
#shellcheck disable=SC2034
C5='\033[0;91m'    # Red

# Installation paths
SYSTEM_INSTALL_DIR="/opt/ccab"
SYSTEM_BIN_DIR="/usr/local/bin"
SYSTEM_CONFIG_DIR="/etc/ccab"
SYSTEM_LOG_DIR="/var/log/ccab"

USER_INSTALL_DIR="$HOME/.local/opt/ccab"
USER_BIN_DIR="$HOME/.local/bin"
USER_CONFIG_DIR="$HOME/.config/ccab"
USER_LOG_DIR="$HOME/.local/var/log/ccab"

# Function to print colored output
print_status() {
    local level="$1"
    local message="$2"
    
    case "$level" in
        "INFO")
            echo -e "${C2}[INFO]${C0} $message"
            ;;
        "WARN")
            echo -e "${C3}[WARN]${C0} $message"
            ;;
        "ERROR")
            echo -e "${C1}[ERROR]${C0} $message"
            ;;
    esac
}

# Check if running as root
check_root() {
    if [[ $EUID -eq 0 ]]; then
        return 0  # Running as root
    else
        return 1  # Not running as root
    fi
}

# Remove system installation
remove_system_installation() {
    print_status "INFO" "Removing system installation..."
    
    # Remove symlink
    if [[ -L "$SYSTEM_BIN_DIR/ccab" ]]; then
        rm "$SYSTEM_BIN_DIR/ccab"
        print_status "INFO" "Removed system command: $SYSTEM_BIN_DIR/ccab"
    fi
    
    # Remove installation directory
    if [[ -d "$SYSTEM_INSTALL_DIR" ]]; then
        rm -rf "$SYSTEM_INSTALL_DIR"
        print_status "INFO" "Removed installation directory: $SYSTEM_INSTALL_DIR"
    fi
    
    # Remove log directory (ask first)
    if [[ -d "$SYSTEM_LOG_DIR" ]]; then
        echo -n "Remove log directory $SYSTEM_LOG_DIR? [y/N]: "
        read -r response
        if [[ "$response" =~ ^[Yy]$ ]]; then
            rm -rf "$SYSTEM_LOG_DIR"
            print_status "INFO" "Removed log directory: $SYSTEM_LOG_DIR"
        else
            print_status "INFO" "Kept log directory: $SYSTEM_LOG_DIR"
        fi
    fi
    
    # Ask about configuration directory
    if [[ -d "$SYSTEM_CONFIG_DIR" ]]; then
        echo -n "Remove configuration directory $SYSTEM_CONFIG_DIR? [y/N]: "
        read -r response
        if [[ "$response" =~ ^[Yy]$ ]]; then
            rm -rf "$SYSTEM_CONFIG_DIR"
            print_status "INFO" "Removed configuration directory: $SYSTEM_CONFIG_DIR"
        else
            print_status "INFO" "Kept configuration directory: $SYSTEM_CONFIG_DIR"
        fi
    fi
}

# Remove user installation
remove_user_installation() {
    print_status "INFO" "Removing user installation..."
    
    # Remove symlink
    if [[ -L "$USER_BIN_DIR/ccab" ]]; then
        rm "$USER_BIN_DIR/ccab"
        print_status "INFO" "Removed user command: $USER_BIN_DIR/ccab"
    fi
    
    # Remove installation directory
    if [[ -d "$USER_INSTALL_DIR" ]]; then
        rm -rf "$USER_INSTALL_DIR"
        print_status "INFO" "Removed installation directory: $USER_INSTALL_DIR"
    fi
    
    # Remove log directory (ask first)
    if [[ -d "$USER_LOG_DIR" ]]; then
        echo -n "Remove log directory $USER_LOG_DIR? [y/N]: "
        read -r response
        if [[ "$response" =~ ^[Yy]$ ]]; then
            rm -rf "$USER_LOG_DIR"
            print_status "INFO" "Removed log directory: $USER_LOG_DIR"
        else
            print_status "INFO" "Kept log directory: $USER_LOG_DIR"
        fi
    fi
    
    # Ask about configuration directory
    if [[ -d "$USER_CONFIG_DIR" ]]; then
        echo -n "Remove configuration directory $USER_CONFIG_DIR? [y/N]: "
        read -r response
        if [[ "$response" =~ ^[Yy]$ ]]; then
            rm -rf "$USER_CONFIG_DIR"
            print_status "INFO" "Removed configuration directory: $USER_CONFIG_DIR"
        else
            print_status "INFO" "Kept configuration directory: $USER_CONFIG_DIR"
        fi
    fi
}

# Detect installations
detect_installations() {
    local system_found=false
    local user_found=false
    
    if [[ -d "$SYSTEM_INSTALL_DIR" || -L "$SYSTEM_BIN_DIR/ccab" ]]; then
        system_found=true
    fi
    
    if [[ -d "$USER_INSTALL_DIR" || -L "$USER_BIN_DIR/ccab" ]]; then
        user_found=true
    fi
    
    echo "$system_found $user_found"
}

# Main uninstall function
main() {
    echo "========================================================================================"
    echo -e "${C2}CCAB Audiobook Converter Uninstall Script v4.0${C0}"
    echo "========================================================================================"
    echo
    
    # Detect installations
    local detection
    detection=$(detect_installations)
    local system_found
    local user_found
    system_found=$(echo "$detection" | cut -d' ' -f1)
    user_found=$(echo "$detection" | cut -d' ' -f2)
    
    if [[ "$system_found" == "false" && "$user_found" == "false" ]]; then
        print_status "INFO" "No CCAB installations found"
        exit 0
    fi
    
    echo "Found installations:"
    if [[ "$system_found" == "true" ]]; then
        echo "  - System installation: $SYSTEM_INSTALL_DIR"
    fi
    if [[ "$user_found" == "true" ]]; then
        echo "  - User installation: $USER_INSTALL_DIR"
    fi
    echo
    
    # Handle system installation
    if [[ "$system_found" == "true" ]]; then
        if check_root; then
            echo -n "Remove system installation? [y/N]: "
            read -r response
            if [[ "$response" =~ ^[Yy]$ ]]; then
                remove_system_installation
            else
                print_status "INFO" "Skipped system installation removal"
            fi
        else
            print_status "WARN" "System installation found but not running as root"
            print_status "WARN" "Run with sudo to remove system installation"
        fi
    fi
    
    # Handle user installation
    if [[ "$user_found" == "true" ]]; then
        echo -n "Remove user installation? [y/N]: "
        read -r response
        if [[ "$response" =~ ^[Yy]$ ]]; then
            remove_user_installation
        else
            print_status "INFO" "Skipped user installation removal"
        fi
    fi
    
    echo
    echo "========================================================================================"
    echo -e "${C2}CCAB Uninstall Complete!${C0}"
    echo "========================================================================================"
    echo
    print_status "INFO" "Thank you for using CCAB Audiobook Converter!"
}

# Run main function if script is executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi