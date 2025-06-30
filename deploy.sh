#!/bin/bash

## ========================================================================================
##       Title: deploy.sh
##      Author: R. L. Paxton
##     Version: 4.0
##        Date: 2025-06-19
##     License: Apache 2.0
## Description: Deployment script for CCAB audiobook converter
##              Installs CCAB to /opt/ccab with proper directory structure
## ========================================================================================

# Colors for output
C0='\033[0;00m'    # Normal
C1='\033[0;92m'    # Green
C4='\033[0;93m'    # Yellow
C5='\033[0;91m'    # Red

# Deployment configuration
INSTALL_DIR="/opt/ccab"
BIN_DIR="/usr/local/bin"
CONFIG_DIR="/etc/ccab"
LOG_DIR="/var/log/ccab"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

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
    if [[ $EUID -ne 0 ]]; then
        print_status "ERROR" "This script must be run as root (use sudo)"
        exit 1
    fi
}

# Validate source files exist
validate_source() {
    local required_files=(
        "ccab-modular.sh"
        "ccab.sh"
        "lib/ccab-config.sh"
        "lib/ccab-security.sh"
        "lib/ccab-utils.sh"
        "lib/ccab-files.sh"
        "lib/ccab-parser.sh"
        "lib/ccab-webscraper.sh"
        "lib/ccab-audio.sh"
        "lib/ccab-metadata.sh"
        "lib/ccab-organization.sh"
        "lib/ccab-processing.sh"
        "config/ccab.conf"
        "config/ccab.example.conf"
        "docs/ARCHITECTURE.md"
    )
    
    print_status "INFO" "Validating source files..."
    
    for file in "${required_files[@]}"; do
        if [[ ! -f "$SCRIPT_DIR/$file" ]]; then
            print_status "ERROR" "Required file not found: $file"
            exit 1
        fi
    done
    
    print_status "INFO" "All source files validated successfully"
}

# Create installation directories
create_directories() {
    print_status "INFO" "Creating installation directories..."
    
    local directories=(
        "$INSTALL_DIR"
        "$INSTALL_DIR/lib"
        "$INSTALL_DIR/docs"
        "$INSTALL_DIR/bin"
        "$CONFIG_DIR"
        "$LOG_DIR"
    )
    
    for dir in "${directories[@]}"; do
        if [[ ! -d "$dir" ]]; then
            mkdir -p "$dir" || {
                print_status "ERROR" "Failed to create directory: $dir"
                exit 1
            }
            print_status "INFO" "Created directory: $dir"
        else
            print_status "INFO" "Directory already exists: $dir"
        fi
    done
}

# Install files
install_files() {
    print_status "INFO" "Installing CCAB files..."
    
    # Install main scripts (use deployment-ready version)
    if [[ -f "$SCRIPT_DIR/ccab-deployed.sh" ]]; then
        cp "$SCRIPT_DIR/ccab-deployed.sh" "$INSTALL_DIR/bin/ccab" || {
            print_status "ERROR" "Failed to install main script"
            exit 1
        }
    else
        cp "$SCRIPT_DIR/ccab-modular.sh" "$INSTALL_DIR/bin/ccab" || {
            print_status "ERROR" "Failed to install main script"
            exit 1
        }
    fi
    chmod +x "$INSTALL_DIR/bin/ccab"
    print_status "INFO" "Installed main script: $INSTALL_DIR/bin/ccab"
    
    # Install original script as backup
    cp "$SCRIPT_DIR/ccab.sh" "$INSTALL_DIR/bin/ccab-original" || {
        print_status "ERROR" "Failed to install original script"
        exit 1
    }
    chmod +x "$INSTALL_DIR/bin/ccab-original"
    print_status "INFO" "Installed original script: $INSTALL_DIR/bin/ccab-original"
    
    # Install library modules
    cp "$SCRIPT_DIR"/lib/*.sh "$INSTALL_DIR/lib/" || {
        print_status "ERROR" "Failed to install library modules"
        exit 1
    }
    print_status "INFO" "Installed library modules to: $INSTALL_DIR/lib/"
    
    # Install documentation
    cp "$SCRIPT_DIR"/docs/*.md "$INSTALL_DIR/docs/" || {
        print_status "ERROR" "Failed to install documentation"
        exit 1
    }
    print_status "INFO" "Installed documentation to: $INSTALL_DIR/docs/"
    
    # Install configuration files
    if [[ ! -f "$CONFIG_DIR/ccab.conf" ]]; then
        cp "$SCRIPT_DIR/config/ccab.conf" "$CONFIG_DIR/ccab.conf" || {
            print_status "ERROR" "Failed to install configuration file"
            exit 1
        }
        print_status "INFO" "Installed configuration: $CONFIG_DIR/ccab.conf"
    else
        print_status "WARN" "Configuration file already exists, not overwriting: $CONFIG_DIR/ccab.conf"
    fi
    
    # Always install example configuration
    cp "$SCRIPT_DIR/config/ccab.example.conf" "$CONFIG_DIR/ccab.example.conf" || {
        print_status "ERROR" "Failed to install example configuration"
        exit 1
    }
    print_status "INFO" "Installed example configuration: $CONFIG_DIR/ccab.example.conf"
}

# Update script paths for installed location
update_script_paths() {
    print_status "INFO" "Updating script paths for installed location..."
    
    # Update hardcoded SCRIPT_DIR path in main script
    sed -i "s|^SCRIPT_DIR=.*|SCRIPT_DIR='$INSTALL_DIR'|g" "$INSTALL_DIR/bin/ccab"
    
    # Update module loading path in main script to use absolute path
    sed -i "s|\$SCRIPT_DIR/lib/|$INSTALL_DIR/lib/|g" "$INSTALL_DIR/bin/ccab"
    sed -i "s|local module_path=\"\$SCRIPT_DIR/lib/\$module\"|local module_path=\"$INSTALL_DIR/lib/\$module\"|g" "$INSTALL_DIR/bin/ccab"
    
    # Update configuration search paths in config module to prioritize system config
    local config_paths=(
        "\"$CONFIG_DIR/ccab.conf\""
        "\"$HOME/.config/ccab/ccab.conf\""
        "\"/etc/ccab/ccab.conf\""
    )
    
    # Replace the config_paths array in the config module
    sed -i "/config_paths=(/,/)/c\\
  config_paths=(\\
    ${config_paths[0]}\\
    ${config_paths[1]}\\
    ${config_paths[2]}\\
  )" "$INSTALL_DIR/lib/ccab-config.sh"
    
    print_status "INFO" "Script paths updated successfully"
}

# Set proper permissions
set_permissions() {
    print_status "INFO" "Setting proper permissions..."
    
    # Set directory permissions
    chmod 755 "$INSTALL_DIR" "$INSTALL_DIR/lib" "$INSTALL_DIR/docs" "$INSTALL_DIR/bin"
    chmod 755 "$CONFIG_DIR"
    chmod 755 "$LOG_DIR"
    
    # Set file permissions
    chmod 755 "$INSTALL_DIR/bin"/*
    chmod 644 "$INSTALL_DIR/lib"/*.sh
    chmod 644 "$INSTALL_DIR/docs"/*.md
    chmod 644 "$CONFIG_DIR"/*.conf
    
    # Make library files executable for sourcing
    chmod 755 "$INSTALL_DIR/lib"/*.sh
    
    print_status "INFO" "Permissions set successfully"
}

# Create system-wide symlink
create_symlink() {
    print_status "INFO" "Creating system-wide symlink..."
    
    if [[ -L "$BIN_DIR/ccab" ]]; then
        rm "$BIN_DIR/ccab"
        print_status "INFO" "Removed existing symlink"
    fi
    
    ln -s "$INSTALL_DIR/bin/ccab" "$BIN_DIR/ccab" || {
        print_status "ERROR" "Failed to create symlink"
        exit 1
    }
    
    print_status "INFO" "Created symlink: $BIN_DIR/ccab -> $INSTALL_DIR/bin/ccab"
}

# Validate installation
validate_installation() {
    print_status "INFO" "Validating installation..."
    
    # Check if main script is executable
    if [[ -x "$INSTALL_DIR/bin/ccab" ]]; then
        print_status "INFO" "Main script is executable"
    else
        print_status "ERROR" "Main script is not executable"
        return 1
    fi
    
    # Check if symlink works
    if command -v ccab &> /dev/null; then
        print_status "INFO" "Command 'ccab' is available in PATH"
    else
        print_status "ERROR" "Command 'ccab' is not available in PATH"
        return 1
    fi
    
    # Test basic functionality
    if ccab --help &> /dev/null; then
        print_status "INFO" "Basic functionality test passed"
    else
        print_status "ERROR" "Basic functionality test failed"
        return 1
    fi
    
    # Test module loading
    if ccab --help 2>&1 | grep -q "Loading module" ; then
        print_status "INFO" "Module loading test passed"
    else
        print_status "WARN" "Module loading test could not be verified (may be normal in non-debug mode)"
    fi
    
    return 0
}

# Display installation summary
display_summary() {
    echo
    echo "========================================================================================"
    echo -e "${C2}CCAB Installation Complete!${C0}"
    echo "========================================================================================"
    echo
    echo "Installation directories:"
    echo "  Program files:    $INSTALL_DIR"
    echo "  Configuration:    $CONFIG_DIR"
    echo "  Logs:            $LOG_DIR"
    echo "  System command:  $BIN_DIR/ccab"
    echo
    echo "Files installed:"
    echo "  Main script:     $INSTALL_DIR/bin/ccab"
    echo "  Original script: $INSTALL_DIR/bin/ccab-original"
    echo "  Library modules: $INSTALL_DIR/lib/"
    echo "  Documentation:   $INSTALL_DIR/docs/"
    echo "  Configuration:   $CONFIG_DIR/ccab.conf"
    echo "  Example config:  $CONFIG_DIR/ccab.example.conf"
    echo
    echo "Usage:"
    echo "  ccab --help                    # Show help"
    echo "  ccab /path/to/audiobooks       # Process audiobooks"
    echo "  ccab -c -r /path/to/files      # Concatenate files recursively"
    echo
    echo "Configuration:"
    echo "  Edit: $CONFIG_DIR/ccab.conf"
    echo "  Example: $CONFIG_DIR/ccab.example.conf"
    echo
    echo "Next steps:"
    echo "  1. Review and customize the configuration file"
    echo "  2. Ensure required dependencies are installed:"
    echo "     - Audio: ffmpeg, ffprobe, lame"
    echo "     - Metadata: mid3v2, fancy_audio (Ruby gem)"  
    echo "     - Web: curl, jq, hxnormalize"
    echo "  3. Set up API keys in the configuration file"
    echo "  4. Test with a sample audiobook directory"
    echo "  5. Verify all 10 modules are loading properly"
    echo
    echo "========================================================================================"
}

# Main deployment function
main() {
    echo "========================================================================================"
    echo -e "${C2}CCAB Audiobook Converter Deployment Script v4.0${C0}"
    echo "========================================================================================"
    echo
    
    check_root
    validate_source
    create_directories
    install_files
    update_script_paths
    set_permissions
    create_symlink
    
    echo -e "${C2}>>> Deployment completed successfully${C0}"
    display_summary
    exit 0
}

# Run main function if script is executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi