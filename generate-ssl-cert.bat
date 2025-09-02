@echo off
REM Generate self-signed SSL certificate for Delphi MCP Server
REM Requires OpenSSL to be installed and in PATH

echo ============================================
echo Generating Self-Signed SSL Certificate
echo ============================================
echo.

REM Check if OpenSSL is available
where openssl >nul 2>&1
if %errorlevel% neq 0 (
    echo ERROR: OpenSSL is not installed or not in PATH
    echo Please install OpenSSL from https://slproweb.com/products/Win32OpenSSL.html
    echo Or via Chocolatey: choco install openssl
    pause
    exit /b 1
)

REM Set certificate parameters
set CERT_DIR=certs
set KEY_FILE=%CERT_DIR%\server.key
set CERT_FILE=%CERT_DIR%\server.crt
set CONFIG_FILE=%CERT_DIR%\openssl.cnf
set DAYS=365

REM Create certs directory if it doesn't exist
if not exist %CERT_DIR% (
    mkdir %CERT_DIR%
    echo Created directory: %CERT_DIR%
)

REM Create OpenSSL configuration file
echo Creating OpenSSL configuration...
(
echo [req]
echo default_bits = 2048
echo distinguished_name = req_distinguished_name
echo req_extensions = v3_req
echo prompt = no
echo.
echo [req_distinguished_name]
echo C = US
echo ST = State
echo L = City
echo O = Organization
echo OU = Development
echo CN = localhost
echo.
echo [v3_req]
echo keyUsage = keyEncipherment, dataEncipherment
echo extendedKeyUsage = serverAuth
echo subjectAltName = @alt_names
echo.
echo [alt_names]
echo DNS.1 = localhost
echo DNS.2 = *.localhost
echo IP.1 = 127.0.0.1
echo IP.2 = ::1
) > %CONFIG_FILE%

REM Generate private key
echo.
echo Generating private key...
openssl genrsa -out %KEY_FILE% 2048
if %errorlevel% neq 0 (
    echo ERROR: Failed to generate private key
    pause
    exit /b 1
)

REM Generate certificate
echo.
echo Generating certificate...
openssl req -new -x509 -sha256 -key %KEY_FILE% -out %CERT_FILE% -days %DAYS% -config %CONFIG_FILE%
if %errorlevel% neq 0 (
    echo ERROR: Failed to generate certificate
    pause
    exit /b 1
)

REM Display certificate info
echo.
echo ============================================
echo Certificate generated successfully!
echo ============================================
echo.
echo Certificate: %CERT_FILE%
echo Private Key: %KEY_FILE%
echo Valid for: %DAYS% days
echo.
echo Certificate details:
openssl x509 -in %CERT_FILE% -text -noout | findstr /C:"Subject:" /C:"Not Before" /C:"Not After"

echo.
echo ============================================
echo Configuration for settings.ini:
echo ============================================
echo.
echo [SSL]
echo Enabled=true
echo CertFile=%CD%\%CERT_FILE%
echo KeyFile=%CD%\%KEY_FILE%
echo.
echo Add these settings to your settings.ini file to enable HTTPS
echo.
pause