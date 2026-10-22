#!/usr/bin/env python3
"""Build HTML content materials for the existing ITORG site, plus a local ZIP.

The generated .html files are editable content sources, not the live site's design
or a deployment package. Navigation targets the published canonical URLs. This
script writes only this repository's Distribution/Website and Artifacts folders.
"""
import html
import json
from pathlib import Path
import zipfile

ROOT = Path(__file__).resolve().parents[1]
SOURCE = json.loads((ROOT / "Tools/LocalizationSource.json").read_text())["strings"]
SPANISH = json.loads((ROOT / "Tools/Translations/western.json").read_text())["es"]
PUBLISHER = "ITORG Krzysztof Radzimski"
CONTACT = "kr@itorg.pl"
SITE = "https://itorg.pl"
PRODUCT_URLS = {
    "pl": f"{SITE}/NetUnstick/",
    "en": f"{SITE}/en/NetUnstick/",
    "es": f"{SITE}/es/NetUnstick/",
}
COPY = {
    "en": {
        "home": "Network diagnostics for Mac",
        "intro": "Check your network path, DNS, internet connectivity and a chosen device without changing network settings.",
        "purchase": "One purchase, no subscription or in-app purchases. Future updates to this app are included at no additional charge. NetUnstick adds no activation or device limit; use and redownloads are subject to Apple's App Store terms.",
        "edition": "The Mac App Store edition is read-only. It does not install a privileged helper or repair system routes, DHCP or VPN settings.",
        "support": "Support", "privacy": "Privacy policy", "contact": "Contact",
        "mail": "If you email support, ITORG processes the contact details and information you choose to send to answer your request. Send only the details needed; do not send passwords, credentials or unredacted network reports. You may ask about or request deletion of your support correspondence at the same address. Necessary records may be retained to handle the request and legal obligations.",
        "apple": "Apple handles purchases and the Apple Account under its own privacy policy. This utility does not receive your payment card details. The hosting provider may process ordinary web access logs; these static pages contain no analytics scripts or tracking cookies.",
        "status": "The App Store release is being prepared. It is not yet available for purchase.",
    },
    "pl": {
        "home": "Diagnostyka sieci dla Maca",
        "intro": "Sprawdź ścieżkę sieci, DNS, dostęp do internetu i wybrane urządzenie bez zmieniania ustawień sieci.",
        "purchase": "Jeden zakup, bez abonamentu i zakupów w aplikacji. Przyszłe aktualizacje tej aplikacji są bez dopłat. NetUnstick nie nakłada limitu aktywacji ani urządzeń; korzystanie i ponowne pobieranie podlegają warunkom App Store Apple.",
        "edition": "Wydanie Mac App Store jest tylko odczytowe. Nie instaluje uprzywilejowanego helpera ani nie naprawia systemowych tras, DHCP lub ustawień VPN.",
        "support": "Wsparcie", "privacy": "Polityka prywatności", "contact": "Kontakt",
        "mail": "Jeśli napiszesz do wsparcia, ITORG przetwarza przekazane dane kontaktowe i informacje, aby odpowiedzieć na zgłoszenie. Wysyłaj tylko potrzebne szczegóły; nie przesyłaj haseł, danych logowania ani nieoczyszczonych raportów sieci. Pod tym samym adresem możesz pytać o korespondencję lub prosić o jej usunięcie. Niezbędne zapisy mogą być zachowane w celu obsługi zgłoszenia i obowiązków prawnych.",
        "apple": "Zakupy i konto Apple obsługuje Apple zgodnie z własną polityką prywatności. Narzędzie nie otrzymuje danych Twojej karty płatniczej. Hosting może przetwarzać zwykłe logi dostępu WWW; te statyczne strony nie zawierają skryptów analitycznych ani śledzących plików cookie.",
        "status": "Wydanie App Store jest w przygotowaniu. Zakup nie jest jeszcze dostępny.",
    },
    "es": {
        "home": "Diagnóstico de red para Mac",
        "intro": "Comprueba la ruta de red, el DNS, la conexión a internet y un dispositivo sin cambiar los ajustes de red.",
        "purchase": "Una sola compra, sin suscripciones ni compras dentro de la app. Las futuras actualizaciones de esta app están incluidas sin coste adicional. NetUnstick no impone límites de activación ni de dispositivos; el uso y las descargas posteriores se rigen por las condiciones del App Store de Apple.",
        "edition": "La edición del Mac App Store es de solo lectura. No instala un componente privilegiado ni repara rutas del sistema, DHCP o ajustes de VPN.",
        "support": "Soporte", "privacy": "Política de privacidad", "contact": "Contacto",
        "mail": "Si escribes al soporte, ITORG trata los datos de contacto y la información que decidas enviar para responder a tu solicitud. Envía solo los detalles necesarios; no envíes contraseñas, credenciales ni informes de red sin anonimizar. Puedes consultar o solicitar la eliminación de tu correspondencia de soporte en la misma dirección. Los registros necesarios pueden conservarse para atender la solicitud y las obligaciones legales.",
        "apple": "Apple gestiona las compras y la cuenta de Apple conforme a su propia política de privacidad. Esta utilidad no recibe los datos de tu tarjeta de pago. El alojamiento puede tratar registros normales de acceso web; estas páginas estáticas no contienen scripts de análisis ni cookies de seguimiento.",
        "status": "La versión del App Store está en preparación. Todavía no está disponible para comprar.",
    },
}


def page_url(language, page):
    return f"{SITE}/NetUnstick/{language}/{page}"


def navigation(language):
    text = COPY[language]
    links = [(PRODUCT_URLS[language], "NetUnstick")]
    links += [(page_url(language, page), text[page]) for page in ("support", "privacy")]
    return "<nav>" + " · ".join(
        f'<a href="{html.escape(url, quote=True)}">{html.escape(label)}</a>'
        for url, label in links
    ) + "</nav>"


def document(language, title, content, *, render_nav=True):
    nav = navigation(language) if render_nav else ""
    return f'''<!doctype html>
<html lang="{language}"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>NetUnstick — {html.escape(title)}</title>
<style>:root{{color-scheme:light dark}}body{{font:1.05rem/1.6 system-ui;margin:3rem auto;padding:0 1.5rem;max-width:48rem}}a{{color:inherit}}h1,h2{{line-height:1.25}}nav,footer{{margin:2rem 0}}</style></head>
<body>{nav}<main><h1>NetUnstick — {html.escape(title)}</h1>{content}</main>
<footer>{html.escape(PUBLISHER)} · <a href="mailto:{CONTACT}">{CONTACT}</a></footer></body></html>
'''


def build():
    output = ROOT / "Distribution/Website"
    pages = []
    for language in COPY:
        for page, title, sections in (
            ("privacy", "help_privacy", ["privacy_local", "privacy_network", "privacy_retention", "privacy_permissions", "privacy_version"]),
            ("support", "help_support", ["help_start", "help_editions", "help_support", "help_safety"]),
        ):
            def text(key):
                return html.escape(SPANISH[key] if language == "es" else SOURCE[key][language])
            content = "\n".join(f"<section><h2>{text(key + '_title')}</h2><p>{text(key + '_body')}</p></section>" for key in sections)
            copy = COPY[language]
            content += f'<section><h2>{copy["contact"]}</h2><p><a href="mailto:{CONTACT}">{CONTACT}</a></p><p>{html.escape(copy["mail"])}</p></section>'
            if page == "privacy":
                content += f'<p>{html.escape(copy["apple"])}</p>'
            path = output / language / f"{page}.html"
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(document(language, COPY[language][page], content), encoding="utf-8")
            pages.append(path)
    materials = '<p>Content materials for the existing ITORG product pages. These files do not replace the published website or its design.</p>'
    materials += "<nav>" + " · ".join(
        f'<a href="{PRODUCT_URLS[language]}">{label}</a>'
        for language, label in (("en", "English"), ("pl", "Polski"), ("es", "Español"))
    ) + "</nav>"
    for language, copy in COPY.items():
        materials += f'<section lang="{language}"><h2>{copy["home"]}</h2><p>{copy["intro"]}</p><p>{copy["edition"]}</p><p>{copy["purchase"]}</p><p>{copy["status"]}</p><p><a href="{page_url(language, "support")}">{copy["support"]}</a> · <a href="{page_url(language, "privacy")}">{copy["privacy"]}</a></p></section>'
    index = output / "index.html"
    index.write_text(document("en", "Content materials", materials, render_nav=False), encoding="utf-8")
    pages.append(index)

    archive = ROOT / "Artifacts/Distribution/NetUnstick-Website.zip"
    archive.parent.mkdir(parents=True, exist_ok=True)
    temporary_archive = archive.with_suffix(".zip.tmp")
    with zipfile.ZipFile(temporary_archive, "w", compression=zipfile.ZIP_DEFLATED) as bundle:
        for path in sorted(pages):
            bundle.write(path, arcname="NetUnstick/" + path.relative_to(output).as_posix())
    temporary_archive.replace(archive)
    print("Prepared 7 HTML content materials in Distribution/Website and Artifacts/Distribution/NetUnstick-Website.zip.")


if __name__ == "__main__":
    build()
