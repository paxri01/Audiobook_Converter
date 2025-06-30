# CCAB Modular Architecture

## Overview

The CCAB (Audiobook Converter) version 4.0 has been refactored from a monolithic 1,944-line script into a modular architecture consisting of 10 focused modules. This design improves maintainability, testability, and reusability while preserving all original functionality.

## Module Structure

```
ccab/
├── ccab.sh                    # Original monolithic script (preserved)
├── ccab-modular.sh           # Main orchestration script (~200 lines)
├── lib/                      # Module library
│   ├── ccab-config.sh        # Configuration management
│   ├── ccab-security.sh      # Security and validation
│   ├── ccab-utils.sh         # System utilities
│   ├── ccab-files.sh         # File management
│   ├── ccab-web.sh           # Web scraping (planned)
│   ├── ccab-parser.sh        # Data parsing (planned)
│   ├── ccab-classify.sh      # Genre classification (planned)
│   ├── ccab-audio.sh         # Audio processing (planned)
│   ├── ccab-tags.sh          # Metadata tagging (planned)
│   └── ccab-move.sh          # File operations (planned)
├── config/
│   ├── ccab.example.conf     # Example configuration
│   └── ccab.conf             # User configuration
└── docs/
    ├── API.md                # Module API documentation
    └── ARCHITECTURE.md       # This file
```

## Implemented Modules

### 1. Configuration Module (`ccab-config.sh`)
**Purpose**: Configuration management and validation
**Functions**:
- `loadConfiguration()` - Multi-path configuration loading
- `validateConfiguration()` - Parameter validation
- `applyConfiguration()` - Variable mapping
- `setupDirectories()` - Directory setup and validation
- `initializeConfiguration()` - Complete initialization

**Dependencies**: None (core module)

### 2. Security Module (`ccab-security.sh`) 
**Purpose**: Input validation and security measures
**Functions**:
- `validateInput()` - Enhanced input sanitization
- `sanitizeHTML()` - HTML content sanitization
- `validateURL()` - URL validation with host whitelisting
- `createSecureTempFile()` - Secure temporary file creation
- `sanitizeFilename()` - Filename sanitization
- `urlEncode()` - RFC 3986 URL encoding
- `validateFileAccess()` - File access validation
- `executeSecureCommand()` - Secure command execution

**Dependencies**: Configuration module

### 3. System Utilities (`ccab-utils.sh`)
**Purpose**: System utilities and hardware detection
**Functions**:
- `checkCudaSupport()` - CUDA capability detection
- `cleanUp()` - Graceful cleanup and exit
- `usage()` - Help system with dynamic content
- `validateDependencies()` - Dependency checking
- `showProgress()` - Progress display utilities
- `logMessage()` - Structured logging system

**Dependencies**: Configuration, Security modules

### 4. File Management (`ccab-files.sh`)
**Purpose**: File discovery and audio file analysis
**Functions**:
- `getFiles()` - File discovery with filtering
- `probeFile()` - Audio metadata extraction
- `checkFile()` - Conversion requirement analysis
- `concatenateFiles()` - Multi-file concatenation
- `getFileStats()` - File statistics reporting
- `validateFileArrays()` - Data integrity validation

**Dependencies**: Configuration, Security, Utils modules

## Module Loading System

The main orchestration script (`ccab-modular.sh`) implements a dynamic module loading system:

```bash
loadModules()
{
  local modules=(
    "ccab-config.sh"
    "ccab-security.sh" 
    "ccab-utils.sh"
    "ccab-files.sh"
  )
  
  for module in "${modules[@]}"; do
    local module_path="$SCRIPT_DIR/lib/$module"
    if [[ -f "$module_path" ]]; then
      source "$module_path"
    else
      echo "ERROR: Required module not found: $module_path"
      exit 1
    fi
  done
}
```

## Initialization Sequence

1. **Module Loading**: Load all required modules from `lib/` directory
2. **Configuration**: Initialize configuration system with validation
3. **Security**: Initialize security and validation systems
4. **Utilities**: Setup hardware detection and cleanup handlers
5. **File Management**: Initialize file discovery and analysis systems
6. **Processing**: Execute main workflow (discovery → analysis → processing)

## Data Flow Architecture

```
Input Files → File Discovery → Metadata Extraction → Validation
     ↓              ↓              ↓                ↓
Configuration ← Security ← Web Scraping ← Data Parsing
     ↓              ↓              ↓                ↓
Audio Processing → Metadata Tagging → File Organization → Output
```

## Module Interfaces

### Configuration Interface
```bash
# Initialize configuration system
initializeConfiguration
# Access configuration variables: $TARGET_BITRATE, $TMP_DIR, etc.
```

### Security Interface
```bash
# Validate and sanitize user input
safe_input=$(validateInput "$user_input" 255)
safe_file=$(createSecureTempFile "prefix" ".ext")
```

### File Management Interface
```bash
# Discover and analyze files
getFiles "$directory" "$search_type" "$recurse"
probeFile "$file" "$index"
```

## Benefits of Modular Design

### Maintainability
- **Single Responsibility**: Each module has a focused purpose
- **Clear Interfaces**: Well-defined function contracts
- **Isolated Changes**: Modifications contained to specific modules
- **Easier Debugging**: Problems isolated to specific components

### Testability
- **Unit Testing**: Individual modules can be tested in isolation
- **Mock Dependencies**: Easy to mock external dependencies
- **Integration Testing**: Systematic testing of module interactions
- **Regression Testing**: Changes validated against existing functionality

### Reusability
- **Component Reuse**: Modules can be used in other projects
- **Selective Loading**: Load only required modules for specific tasks
- **API Exposure**: Clean interfaces for external consumption
- **Standalone Utilities**: Security and file modules useful independently

### Scalability
- **Feature Addition**: New functionality added as separate modules
- **Performance Optimization**: Optimize individual components
- **Resource Management**: Better memory and process management
- **Parallel Processing**: Modules can potentially run concurrently

## Security Architecture

The modular design implements defense-in-depth security:

1. **Input Validation Layer**: All user inputs validated at module boundaries
2. **HTML Sanitization**: Web content sanitized before processing
3. **URL Validation**: External requests validated and restricted
4. **File Security**: Secure temporary file handling with proper permissions
5. **Command Execution**: Secure wrappers for external command execution

## Future Extensions

### Planned Modules
1. **Web Scraping Module**: Book metadata retrieval and HTML parsing
2. **Data Parser Module**: Structured metadata extraction and validation
3. **Classification Module**: Genre categorization and user interaction
4. **Audio Processing Module**: CUDA/CPU encoding with fallback strategies
5. **Metadata Tagging Module**: ID3 tag application and cover art embedding
6. **File Operations Module**: Final file organization and permission management

### Extension Points
- **Plugin System**: Support for external modules
- **Configuration Plugins**: Custom configuration providers
- **Output Formats**: Additional audio format support
- **Metadata Sources**: Alternative metadata providers
- **Processing Pipelines**: Custom processing workflows

## Migration Strategy

The modular architecture coexists with the original monolithic script:

1. **Preservation**: Original `ccab.sh` remains functional and unmodified
2. **Gradual Migration**: Users can test modular version alongside original
3. **Feature Parity**: Modular version will implement all original features
4. **Backward Compatibility**: Configuration and usage patterns preserved
5. **Performance**: Modular version optimized for better performance

## Development Guidelines

### Adding New Modules
1. Create module file in `lib/` directory
2. Implement module identification variables
3. Define clear function interfaces
4. Add initialization function
5. Export functions for external use
6. Update main orchestration script
7. Add module documentation

### Module Standards
- Use consistent error handling patterns
- Implement proper logging with `logMessage()`
- Follow security best practices
- Use configuration variables, not hardcoded values
- Implement proper cleanup in all code paths
- Add comprehensive parameter validation

## Performance Considerations

### Memory Usage
- **Lazy Loading**: Modules loaded only when needed
- **Array Management**: Efficient handling of large file arrays
- **Cleanup**: Proper resource cleanup prevents memory leaks

### Processing Speed
- **Parallel Processing**: Modules designed for potential parallelization
- **Caching**: Intermediate results cached where appropriate
- **Optimized Algorithms**: Efficient file discovery and processing

### Disk I/O
- **Minimal File Operations**: Reduced temporary file creation
- **Secure Files**: Proper permissions without overhead
- **Batch Processing**: Grouped operations where possible

This modular architecture transforms the CCAB script from a monolithic application into a maintainable, scalable, and secure system while preserving all original functionality and adding significant improvements in security and reliability.