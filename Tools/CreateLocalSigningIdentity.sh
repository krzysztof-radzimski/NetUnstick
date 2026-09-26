#!/bin/zsh
set -euo pipefail

identity='NetUnstick Local Code Signing'
keychain="$HOME/Library/Keychains/login.keychain-db"
umask 077
temporary_directory="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/netunstick-signing.XXXXXX")"
trap '/bin/rm -rf -- "$temporary_directory"' EXIT INT TERM

if /usr/bin/security find-identity -v -p codesigning "$keychain" | /usr/bin/grep -Fq "\"$identity\""; then
    print "Tożsamość '$identity' jest już w pęku kluczy login; zachowuję jej klucz prywatny."
    exit 0
fi
if /usr/bin/security find-identity -p codesigning "$keychain" | /usr/bin/grep -Fq "\"$identity\""; then
    print 'Tożsamość istnieje; przywracam zaufanie użytkownika ograniczone do podpisywania kodu.'
    /usr/bin/security find-certificate -c "$identity" -p "$keychain" > "$temporary_directory/certificate.pem"
    /usr/bin/security add-trusted-cert -r trustRoot -p codeSign -k "$keychain" "$temporary_directory/certificate.pem"
    /usr/bin/security find-identity -v -p codesigning "$keychain" | /usr/bin/grep -Fq "\"$identity\""
    exit 0
fi
if /usr/bin/security find-certificate -a -c "$identity" -p "$keychain" 2>/dev/null | /usr/bin/grep -q 'BEGIN CERTIFICATE'; then
    print -u2 "Certyfikat '$identity' istnieje bez ważnego klucza podpisu. Napraw go ręcznie; nie tworzę nowego klucza pod tą samą nazwą."
    exit 1
fi

cat > "$temporary_directory/openssl.cnf" <<'CONFIG'
[ req ]
distinguished_name = subject
x509_extensions = codesign
prompt = no

[ subject ]
CN = NetUnstick Local Code Signing

[ codesign ]
basicConstraints = critical, CA:FALSE
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
CONFIG

/usr/bin/openssl genrsa -out "$temporary_directory/private-key.pem" 3072 >/dev/null 2>&1
/usr/bin/openssl req -new -x509 -sha256 -days 3650 \
    -key "$temporary_directory/private-key.pem" \
    -config "$temporary_directory/openssl.cnf" -extensions codesign \
    -out "$temporary_directory/certificate.pem"
import_password="$(/usr/bin/openssl rand -hex 24)"
/usr/bin/openssl pkcs12 -export -passout "pass:$import_password" \
    -inkey "$temporary_directory/private-key.pem" \
    -in "$temporary_directory/certificate.pem" \
    -name "$identity" -out "$temporary_directory/identity.p12"
/usr/bin/security import "$temporary_directory/identity.p12" -k "$keychain" -P "$import_password" -T /usr/bin/codesign
unset import_password
print 'macOS może poprosić o zgodę na zaufanie temu certyfikatowi wyłącznie do podpisywania kodu.'
/usr/bin/security add-trusted-cert -r trustRoot -p codeSign -k "$keychain" "$temporary_directory/certificate.pem"

if ! /usr/bin/security find-identity -v -p codesigning "$keychain" | /usr/bin/grep -Fq "\"$identity\""; then
    print -u2 "Import nie utworzył ważnej tożsamości podpisu '$identity'."
    exit 1
fi
print "Utworzono trwałą lokalną tożsamość '$identity' w pęku kluczy login."
