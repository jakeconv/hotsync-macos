/*
 * hotsync-session: eine HotSync-Sitzung an genau einem Anschluss.
 *
 * Wozu: pilot-xfer bekommt die zu installierenden Dateien schon beim Start
 * und kann nicht erst fragen, WELCHER Palm sich gemeldet hat. HotSync
 * ordnet Dateien aber dem Palm zu (Profil = Benutzername + User-ID). Dieses
 * Werkzeug nimmt die Verbindung an, meldet die Identität des Palms und
 * wartet dann auf Anweisungen der App - so landet nie eine Datei auf dem
 * falschen Palm, auch wenn an einer Kette mehrere Palms hängen.
 *
 * Aufruf:   hotsync-session --port usb: [--timeout SEK]
 *           hotsync-session --port /dev/cu.usbserial-A1 [--timeout SEK]
 *           (Baudrate seriell über PILOTRATE, wie bei pilot-link üblich)
 *
 * stdout:   ein JSON-Objekt pro Zeile (Ereignisse, siehe emit_*)
 * stdin:    eine Anweisung pro Zeile, erst nach "connected" - solange keine
 *           kommt (z. B. während die App fragt, ob ein neuer Palm angelegt
 *           werden soll), hält das Werkzeug die Verbindung zum Palm offen:
 *             install <Pfad>   Datei installieren
 *             setuser <ID> <Name>  Palm ohne Benutzer übernimmt ein Profil
 *             log <Text>       Eintrag ins HotSync-Log des Palms
 *             backup <Ordner>  die Datenbanken im RAM nach <Ordner> sichern
 *                              (nur die seit der letzten Sicherung geänderten)
 *             getrom <Ordner>  das ROM nach <Ordner>/PalmOS-<Version>.rom
 *                              auslesen (nur Palm OS 1-4)
 *           Datensätze (für den Abgleich, siehe "Datensätze" unten):
 *             listdbs          die Datenbanken im RAM auflisten
 *             opendb read|write <Name>   eine Datenbank öffnen
 *             closedb          sie schließen
 *             readall          alle Datensätze lesen
 *             readchanged      nur die geänderten/gelöschten lesen
 *             writerec <ID> <Attribute> <Kategorie> <Hex>
 *                              Datensatz schreiben (ID 0: neu)
 *             deleterec <ID>   Datensatz löschen
 *             readappinfo      AppInfo-Block (Kategorien) lesen
 *             writeappinfo <Hex>   AppInfo-Block schreiben
 *             resetflags       nach dem Abgleich: Gelöschte entfernen,
 *                              "geändert" zurücksetzen
 *             syncinfo         letzter Rechner und Zeitpunkt des Abgleichs
 *             setsyncpc <ID>   dieser Rechner hat gerade abgeglichen
 *             end              Sitzung sauber beenden
 *
 * Exit:     0 Sitzung beendet, 1 Fehler, 2 kein Palm innerhalb des Timeouts
 */

#include <errno.h>
#include <limits.h>
#include <poll.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <time.h>
#include <utime.h>
#include <unistd.h>

#include "pi-dlp.h"
#include "pi-file.h"
#include "pi-socket.h"
#include "pi-syspkt.h"

/* ---- JSON-Ausgabe -------------------------------------------------------- */

/* Palm OS speichert Text in Windows-1252; für JSON brauchen wir UTF-8.
 * 0x80-0x9F weichen von Latin-1 ab, diese Tabelle deckt sie ab. */
static const unsigned short cp1252_high[32] = {
	0x20AC, 0xFFFD, 0x201A, 0x0192, 0x201E, 0x2026, 0x2020, 0x2021,
	0x02C6, 0x2030, 0x0160, 0x2039, 0x0152, 0xFFFD, 0x017D, 0xFFFD,
	0xFFFD, 0x2018, 0x2019, 0x201C, 0x201D, 0x2022, 0x2013, 0x2014,
	0x02DC, 0x2122, 0x0161, 0x203A, 0x0153, 0xFFFD, 0x017E, 0x0178
};

static void put_utf8(unsigned int cp)
{
	if (cp < 0x80) {
		putchar((int)cp);
	} else if (cp < 0x800) {
		putchar(0xC0 | (cp >> 6));
		putchar(0x80 | (cp & 0x3F));
	} else {
		putchar(0xE0 | (cp >> 12));
		putchar(0x80 | ((cp >> 6) & 0x3F));
		putchar(0x80 | (cp & 0x3F));
	}
}

/* Schreibt einen JSON-String. palm_text: Quelle ist Windows-1252 (vom
 * Palm), sonst UTF-8 (Pfade, Meldungen) und wird nur maskiert. */
static void put_json_string(const char *s, int palm_text)
{
	const unsigned char *p = (const unsigned char *)s;

	putchar('"');
	for (; *p; p++) {
		unsigned int c = *p;
		if (c == '"' || c == '\\') {
			putchar('\\');
			putchar((int)c);
		} else if (c < 0x20) {
			printf("\\u%04x", c);
		} else if (c >= 0x80 && palm_text) {
			put_utf8(c < 0xA0 ? cp1252_high[c - 0x80] : c);
		} else {
			putchar((int)c);
		}
	}
	putchar('"');
}

/* Alle Ereignisse gehen sofort raus: die App reagiert auf jede Zeile. */
static void emit_end(void)
{
	fputs("}\n", stdout);
	fflush(stdout);
}

static void emit_begin(const char *event)
{
	fputs("{\"event\":", stdout);
	put_json_string(event, 0);
}

static void emit_str(const char *key, const char *value, int palm_text)
{
	printf(",\"%s\":", key);
	put_json_string(value, palm_text);
}

static void emit_int(const char *key, long value)
{
	printf(",\"%s\":%ld", key, value);
}

static void emit_error(const char *stage, const char *fmt, ...)
{
	char message[256];
	va_list ap;

	va_start(ap, fmt);
	vsnprintf(message, sizeof(message), fmt, ap);
	va_end(ap);

	emit_begin("error");
	emit_str("stage", stage, 0);
	emit_str("message", message, 0);
	emit_end();
}

/* Gegenrichtung für "setuser": UTF-8 von der App nach Windows-1252 für den
 * Palm. Zeichen, die es dort nicht gibt, werden zu '?'. */
static void utf8_to_cp1252(const char *in, char *out, size_t out_size)
{
	const unsigned char *p = (const unsigned char *)in;
	size_t n = 0;

	while (*p && n + 1 < out_size) {
		unsigned int cp;
		int i;

		if (*p < 0x80) {
			cp = *p++;
		} else if ((*p & 0xE0) == 0xC0 && p[1]) {
			cp = ((p[0] & 0x1F) << 6) | (p[1] & 0x3F);
			p += 2;
		} else if ((*p & 0xF0) == 0xE0 && p[1] && p[2]) {
			cp = ((p[0] & 0x0F) << 12) | ((p[1] & 0x3F) << 6) | (p[2] & 0x3F);
			p += 3;
		} else {
			/* 4-Byte-Folgen (Emoji) und kaputte Bytes überspringen */
			p++;
			while ((*p & 0xC0) == 0x80)
				p++;
			out[n++] = '?';
			continue;
		}

		if (cp < 0x80 || (cp >= 0xA0 && cp <= 0xFF)) {
			out[n++] = (char)cp;
			continue;
		}
		for (i = 0; i < 32; i++) {
			if (cp1252_high[i] == cp && cp != 0xFFFD)
				break;
		}
		out[n++] = i < 32 ? (char)(0x80 + i) : '?';
	}
	out[n] = '\0';
}

/* ---- Installation ------------------------------------------------------- */

static const char *base_name(const char *path)
{
	const char *slash = strrchr(path, '/');
	return slash ? slash + 1 : path;
}

/* Fortschritt je übertragenem Datensatz - die App zeigt damit, dass die
 * Übertragung lebt, und kann einen Hänger von einer großen Datei
 * unterscheiden. */
static int install_progress(int sd, pi_progress_t *progress)
{
	(void)sd;
	emit_begin("progress");
	emit_int("bytes", (long)progress->transferred_bytes);
	emit_end();
	return PI_TRANSFER_CONTINUE;
}

/* Installiert eine Datei und meldet "installed" oder "failed". Die Gründe
 * kommen als Rohcodes; die Zuordnung zu Texten macht die App (HotSyncCore),
 * damit es dafür genau eine Stelle gibt. */
static void install_file(int sd, const char *path)
{
	const char *name = base_name(path);
	struct stat sbuf;
	struct CardInfo card;
	unsigned long ram_free = 0;
	pi_file_t *pf;

	emit_begin("installing");
	emit_str("file", name, 0);
	emit_end();

	if (stat(path, &sbuf) != 0 || (pf = pi_file_open(path)) == NULL) {
		emit_begin("failed");
		emit_str("file", name, 0);
		emit_str("reason", "unreadableFile", 0);
		emit_end();
		return;
	}

	/* Freien Speicher aller Karten summieren wie pilot-xfer: lieber vorher
	 * ablehnen als mitten in der Übertragung abbrechen. */
	card.card = -1;
	card.more = 1;
	while (card.more) {
		if (dlp_ReadStorageInfo(sd, card.card + 1, &card) < 0)
			break;
		ram_free += card.ramFree;
	}
	if (ram_free > 0 && (unsigned long)sbuf.st_size > ram_free) {
		emit_begin("failed");
		emit_str("file", name, 0);
		emit_str("reason", "notEnoughSpace", 0);
		emit_int("needed", (long)sbuf.st_size);
		emit_int("available", (long)ram_free);
		emit_end();
		pi_file_close(pf);
		return;
	}

	if (pi_file_install(pf, sd, 0, install_progress) < 0) {
		emit_begin("failed");
		emit_str("file", name, 0);
		emit_str("reason", "palmError", 0);
		emit_int("error", pi_error(sd));
		emit_int("palmOSError", pi_palmos_error(sd));
		emit_end();
	} else {
		emit_begin("installed");
		emit_str("file", name, 0);
		emit_int("bytes", (long)sbuf.st_size);
		emit_end();
	}
	pi_file_close(pf);
}

/* ---- Sicherung ---------------------------------------------------------- */

/* Dateiname aus dem Datenbanknamen: '/' und Steuerzeichen gehen in keinen
 * Dateinamen, '=' maskiert (wie pilot-xfer: "=2F" für '/'). Palm-Text ist
 * Windows-1252, der Dateiname UTF-8 wie in der JSON-Ausgabe. */
static void file_name_for(char *out, size_t size, const struct DBInfo *info)
{
	const unsigned char *p = (const unsigned char *)info->name;
	size_t n = 0;

	for (; *p && n + 8 < size; p++) {
		unsigned int c = *p;

		if (c == '/' || c == '=' || c < 0x20 || c == 0x7F) {
			n += snprintf(out + n, size - n, "=%02X", c);
		} else if (c >= 0x80) {
			unsigned int cp = c < 0xA0 ? cp1252_high[c - 0x80] : c;

			if (cp < 0x800) {
				out[n++] = (char)(0xC0 | (cp >> 6));
				out[n++] = (char)(0x80 | (cp & 0x3F));
			} else {
				out[n++] = (char)(0xE0 | (cp >> 12));
				out[n++] = (char)(0x80 | ((cp >> 6) & 0x3F));
				out[n++] = (char)(0x80 | (cp & 0x3F));
			}
		} else {
			out[n++] = (char)c;
		}
	}
	out[n] = '\0';
	strncat(out, (info->flags & dlpDBFlagResource) ? ".prc" : ".pdb", size - strlen(out) - 1);
}

/* Datenbanken, die nicht in eine Sicherung gehören - dieselben wie bei
 * pilot-xfer: Datenbanken dieser Creator setzen manche Palm OS 5-Geräte beim
 * Lesen zurück oder sind nur Caches (PACE), "Unsaved Preferences" ist ein
 * Arbeitsstand des Systems. */
#define FOURCC(a, b, c, d) \
	(((unsigned long)(a) << 24) | ((unsigned long)(b) << 16) | ((unsigned long)(c) << 8) | (unsigned long)(d))

static int skip_in_backup(const struct DBInfo *info)
{
	static const unsigned long creators[] = {
		FOURCC('p', 'p', 'p', '_'), FOURCC('u', '8', 'E', 'Z'),
		FOURCC('P', 'M', 'H', 'a'), FOURCC('P', 'M', 'N', 'e'),	/* Phone Link Update */
		FOURCC('F', 'n', 't', '1'),					/* Hires-Fonts */
		FOURCC('m', 'o', 'd', 'm'), FOURCC('a', '6', '8', 'k')		/* PACE-Cache */
	};
	size_t i;

	for (i = 0; i < sizeof(creators) / sizeof(creators[0]); i++)
		if (info->creator == creators[i])
			return 1;
	return strcmp(info->name, "Unsaved Preferences") == 0;
}

static void emit_backup_failed(const char *name, const char *reason, int sd)
{
	emit_begin("backupFailed");
	emit_str("file", name, 0);
	emit_str("reason", reason, 0);
	if (sd >= 0) {
		emit_int("error", pi_error(sd));
		emit_int("palmOSError", pi_palmos_error(sd));
	}
	emit_end();
}

/* "backup <Ordner>": die Datenbanken im RAM nach <Ordner> sichern, eine
 * .prc/.pdb je Datenbank. Seit der letzten Sicherung unverändert (das
 * Änderungsdatum auf dem Palm ist das Dateidatum, wie bei pilot-xfer -u):
 * übersprungen. Geschrieben wird über <Datei>.part, damit ein abgebrochener
 * HotSync die vorige Sicherung einer Datenbank nicht zerstört.
 * Ereignisse: backupStarted (mit Gesamtzahl), je Datenbank backingUp und
 * backedUp / backupUnchanged / backupFailed, am Ende backupFinished. */
static void backup(int sd, const char *dir)
{
	struct DBInfo *list = NULL;
	int count = 0, capacity = 0, index = 0, i;
	int saved = 0, unchanged = 0, failed = 0;
	pi_buffer_t *buffer;

	if (mkdir(dir, 0755) != 0 && errno != EEXIST) {
		emit_error("backup", "cannot create %s (%s)", dir, strerror(errno));
		return;
	}
	buffer = pi_buffer_new(sizeof(struct DBInfo));
	if (buffer == NULL) {
		emit_error("backup", "out of memory");
		return;
	}

	/* erst die ganze Liste: die Gesamtzahl für den Fortschritt. Ihr Ende
	 * meldet der Palm als "nicht gefunden". */
	while (dlp_ReadDBList(sd, 0, dlpDBListRAM, index, buffer) >= 0) {
		struct DBInfo info;

		memcpy(&info, buffer->data, sizeof(struct DBInfo));
		index = info.index + 1;
		if (skip_in_backup(&info))
			continue;
		if (count == capacity) {
			struct DBInfo *grown;

			capacity = capacity ? capacity * 2 : 64;
			grown = realloc(list, capacity * sizeof(struct DBInfo));
			if (grown == NULL) {
				emit_error("backup", "out of memory");
				free(list);
				pi_buffer_free(buffer);
				return;
			}
			list = grown;
		}
		list[count++] = info;
	}
	pi_buffer_free(buffer);
	if (!pi_socket_connected(sd)) {
		emit_error("backup", "the Palm does not answer any more");
		free(list);
		return;
	}

	emit_begin("backupStarted");
	emit_str("directory", dir, 0);
	emit_int("total", count);
	emit_end();

	for (i = 0; i < count; i++) {
		struct DBInfo info = list[i];
		char name[256], path[PATH_MAX], part[PATH_MAX + 8];
		struct stat sbuf;
		struct utimbuf times;
		pi_file_t *pf;

		/* "Abbrechen" auf dem Palm beendet die Sicherung */
		if (!pi_socket_connected(sd) || dlp_OpenConduit(sd) < 0) {
			emit_error("backup", "cancelled on the Palm or connection lost");
			break;
		}

		file_name_for(name, sizeof(name), &info);
		snprintf(path, sizeof(path), "%s/%s", dir, name);

		if (stat(path, &sbuf) == 0 && sbuf.st_mtime == info.modifyDate) {
			emit_begin("backupUnchanged");
			emit_str("file", name, 0);
			emit_int("index", i + 1);
			emit_end();
			unchanged++;
			continue;
		}

		emit_begin("backingUp");
		emit_str("file", name, 0);
		emit_int("index", i + 1);
		emit_int("total", count);
		emit_end();

		/* geöffnet und schreibgeschützt gehören nicht in die Datei */
		info.flags &= ~(dlpDBFlagOpen | dlpDBFlagReadOnly);
		snprintf(part, sizeof(part), "%s.part", path);
		pf = pi_file_create(part, &info);
		if (pf == NULL) {
			emit_backup_failed(name, "unwritableFile", -1);
			failed++;
			continue;
		}
		if (pi_file_retrieve(pf, sd, 0, install_progress) < 0) {
			emit_backup_failed(name, "palmError", sd);
			pi_file_close(pf);
			unlink(part);
			failed++;
			continue;
		}
		if (pi_file_close(pf) < 0) {	/* schreibt die Datei */
			emit_backup_failed(name, "unwritableFile", -1);
			unlink(part);
			failed++;
			continue;
		}
		/* Dateidatum = Änderungsdatum auf dem Palm: so erkennt die nächste
		 * Sicherung, dass sich nichts geändert hat */
		times.actime = info.createDate;
		times.modtime = info.modifyDate;
		utime(part, &times);
		if (rename(part, path) != 0) {
			emit_backup_failed(name, "unwritableFile", -1);
			unlink(part);
			failed++;
			continue;
		}

		emit_begin("backedUp");
		emit_str("file", name, 0);
		emit_int("bytes", stat(path, &sbuf) == 0 ? (long)sbuf.st_size : 0);
		emit_end();
		saved++;
	}
	free(list);

	emit_begin("backupFinished");
	emit_int("saved", saved);
	emit_int("unchanged", unchanged);
	emit_int("failed", failed);
	emit_end();
}

/* ---- ROM --------------------------------------------------------------- */

/* Bytes je RPC-Aufruf und wie oft dabei nach "Abbrechen" auf dem Palm und
 * nach dem Fortschritt geschaut wird - wie pilot-getrom */
#define ROM_CHUNK		256
#define ROM_CANCEL_EVERY	8
#define ROM_PROGRESS_EVERY	16

/* Text unten auf den Bildschirm des Palms (WinDrawChars). Nur zur Anzeige:
 * scheitert es, geht das Auslesen trotzdem weiter. dlp_RPC schreibt die
 * Daten jedes Zeiger-Parameters nach dem Aufruf zurück - der Text muss
 * daher in einem beschreibbaren Puffer liegen, nicht in einer Konstante. */
static void draw_on_palm(int sd, const char *text, int x)
{
	struct RPC_params p;
	char buffer[64];
	size_t len = strlen(text);

	if (len >= sizeof(buffer))
		len = sizeof(buffer) - 1;
	memcpy(buffer, text, len);
	buffer[len] = '\0';
	PackRPC(&p, 0xA220, RPC_IntReply, RPC_Ptr(buffer, len),
		RPC_Short(len), RPC_Short(x), RPC_Short(28), RPC_End);
	dlp_RPC(sd, &p, NULL);
}

/* "getrom <Ordner>": das ROM des Palms lesen, über DLP-RPC wie pilot-getrom
 * (MemMove aus dem ROM in 256-Byte-Stücken). Palm OS 5 kennt diese RPCs
 * nicht mehr und stürzt ab - dort nur "romUnsupported". Anders als
 * pilot-getrom bricht jeder RPC-Fehler ab, statt Müll in die Datei zu
 * schreiben; geschrieben wird über <Datei>.part.
 * Ereignisse: romStarted (Datei, Version, Größe), romProgress (Bytes),
 * romFinished oder romUnsupported, sonst error. */
static void get_rom(int sd, const char *dir)
{
	struct RPC_params p;
	unsigned long feature, rom_start, rom_length, offset = 0, chunks = 0;
	int major, minor, bugfix;
	char version[32], name[64], path[PATH_MAX], part[PATH_MAX + 8];
	unsigned char buffer[ROM_CHUNK];
	FILE *out;

	if (dlp_ReadFeature(sd, FOURCC('p', 's', 'y', 's'), 1, &feature) < 0) {
		emit_error("rom", "cannot read the Palm OS version");
		return;
	}
	major = (int)(((feature >> 28) & 0xF) * 10 + ((feature >> 24) & 0xF));
	minor = (int)((feature >> 20) & 0xF);
	bugfix = (int)((feature >> 16) & 0xF);
	snprintf(version, sizeof(version), "%d.%d.%d", major, minor, bugfix);

	if (major >= 5) {
		emit_begin("romUnsupported");
		emit_str("version", version, 0);
		emit_end();
		return;
	}
	if (mkdir(dir, 0755) != 0 && errno != EEXIST) {
		emit_error("rom", "cannot create %s (%s)", dir, strerror(errno));
		return;
	}

	/* Anfang und Länge des ROM (Karte 0) */
	PackRPC(&p, 0xA23E, RPC_IntReply, RPC_Long(0xFFFFFFFF), RPC_End);
	if (dlp_RPC(sd, &p, &rom_start) < 0) {
		emit_error("rom", "cannot find the ROM (%d)", pi_error(sd));
		return;
	}
	PackRPC(&p, 0xA23E, RPC_IntReply, RPC_Long(rom_start), RPC_End);
	if (dlp_RPC(sd, &p, &rom_length) < 0) {
		emit_error("rom", "cannot read the ROM size (%d)", pi_error(sd));
		return;
	}
	/* Palm OS 3.0 meldet 1 MB für ein ROM von 2 MB (wie pilot-getrom) */
	if (major == 3 && minor == 0 && rom_length == 0x100000)
		rom_length = 0x200000;
	if (rom_length == 0 || rom_length > 0x4000000) {
		emit_error("rom", "implausible ROM size %lu", rom_length);
		return;
	}

	snprintf(name, sizeof(name), "PalmOS-%s.rom", version);
	snprintf(path, sizeof(path), "%s/%s", dir, name);
	snprintf(part, sizeof(part), "%s.part", path);
	out = fopen(part, "wb");
	if (out == NULL) {
		emit_error("rom", "cannot write %s (%s)", part, strerror(errno));
		return;
	}

	emit_begin("romStarted");
	emit_str("file", name, 0);
	emit_str("version", version, 0);
	emit_int("total", (long)rom_length);
	emit_end();

	/* Bildschirm des Palms leeren (WinEraseWindow), dann der Hinweis */
	PackRPC(&p, 0xA164, RPC_IntReply, RPC_Byte(1), RPC_End);
	dlp_RPC(sd, &p, NULL);
	draw_on_palm(sd, "Downloading ROM ...", 0);

	while (offset < rom_length) {
		unsigned long len = rom_length - offset;

		if (len > ROM_CHUNK)
			len = ROM_CHUNK;
		PackRPC(&p, 0xA026, RPC_IntReply, RPC_Ptr(buffer, len),
			RPC_Long(rom_start + offset), RPC_Long(len), RPC_End);
		if (dlp_RPC(sd, &p, NULL) < 0) {
			emit_error("rom", "reading the ROM at %lu failed (%d)", offset, pi_error(sd));
			break;
		}
		if (fwrite(buffer, 1, len, out) != len) {
			emit_error("rom", "cannot write %s (%s)", part, strerror(errno));
			break;
		}
		offset += len;
		chunks++;

		if (chunks % ROM_CANCEL_EVERY == 0 && dlp_OpenConduit(sd) < 0) {
			emit_error("rom", "cancelled on the Palm or connection lost");
			break;
		}
		if (chunks % ROM_PROGRESS_EVERY == 0 || offset == rom_length) {
			char text[32];

			emit_begin("romProgress");
			emit_int("bytes", (long)offset);
			emit_end();
			if (chunks % (ROM_PROGRESS_EVERY * 16) == 0) {
				snprintf(text, sizeof(text), "%lu KB", offset / 1024);
				draw_on_palm(sd, text, 110);
			}
		}
	}

	if (fclose(out) != 0 && offset == rom_length) {
		emit_error("rom", "cannot write %s (%s)", part, strerror(errno));
		offset = 0;
	}
	if (offset < rom_length) {
		unlink(part);
		return;
	}
	if (rename(part, path) != 0) {
		emit_error("rom", "cannot write %s (%s)", path, strerror(errno));
		unlink(part);
		return;
	}
	emit_begin("romFinished");
	emit_str("file", name, 0);
	emit_int("bytes", (long)rom_length);
	emit_end();
}

/* ---- Sitzung ------------------------------------------------------------ */

static int connect_palm(const char *port, int timeout)
{
	int listen_sd, sd;

	listen_sd = pi_socket(PI_AF_PILOT, PI_SOCK_STREAM, PI_PF_DLP);
	if (listen_sd < 0) {
		emit_error("socket", "unable to create socket");
		return -1;
	}
	if (pi_bind(listen_sd, port) < 0) {
		emit_error("bind", "unable to bind to %s", port);
		pi_close(listen_sd);
		return -1;
	}
	if (pi_listen(listen_sd, 1) < 0) {
		emit_error("listen", "unable to listen on %s", port);
		pi_close(listen_sd);
		return -1;
	}

	emit_begin("listening");
	emit_str("port", port, 0);
	emit_end();

	/* Kein Palm innerhalb des Timeouts meldet libpisock je Anschluss anders:
	 * - USB: u_wait_for_device liefert 0, pi_usb_accept reicht das durch -
	 *   pi_accept_to gibt 0 zurück (nie ein gültiger Socket, das ist stdin)
	 *   und lässt den Listener offen.
	 * - seriell: PI_ERR_SOCK_TIMEOUT; bei negativen Werten hat pi_accept_to
	 *   den Listener schon selbst geschlossen. */
	sd = pi_accept_to(listen_sd, NULL, NULL, timeout);
	if (sd == 0) {
		pi_close(listen_sd);
		emit_begin("timeout");
		emit_end();
		return -2;
	}
	if (sd == PI_ERR_SOCK_TIMEOUT) {
		emit_begin("timeout");
		emit_end();
		return -2;
	}
	if (sd < 0) {
		emit_error("accept", "error accepting data on %s (%d)", port, sd);
		return -1;
	}
	return sd;
}

/* Der beim Verbinden gelesene Benutzer: "setuser" ändert nur Name und ID
 * und schreibt die übrigen Felder unverändert zurück. */
static struct PilotUser palm_user;

static int report_identity(int sd)
{
	struct SysInfo sys;
	struct PilotUser user;

	if (dlp_ReadSysInfo(sd, &sys) < 0) {
		emit_error("sysinfo", "unable to read system info");
		return -1;
	}
	if (dlp_ReadUserInfo(sd, &user) < 0) {
		emit_error("userinfo", "unable to read user info");
		return -1;
	}

	palm_user = user;

	emit_begin("connected");
	emit_str("user", user.username, 1);
	emit_int("userId", (long)user.userID);
	emit_int("romVersion", (long)sys.romVersion);
	emit_end();
	return 0;
}

/* Gibt einem Palm ohne Benutzer die Identität seines Profils:
 * "setuser <ID> <Name>". Danach erkennt HotSync ihn an der ID wieder. */
static void write_user(int sd, const char *args)
{
	char *end;
	unsigned long id = strtoul(args, &end, 10);
	struct PilotUser user = palm_user;

	if (end == args || *end != ' ' || id == 0) {
		emit_error("setuser", "usage: setuser <ID> <name>");
		return;
	}
	utf8_to_cp1252(end + 1, user.username, sizeof(user.username));
	user.userID = id;
	user.viewerID = 0;
	user.lastSyncPC = 0;

	if (dlp_WriteUserInfo(sd, &user) < 0) {
		emit_error("setuser", "unable to write user info (%d, PalmOS 0x%04x)",
			pi_error(sd), pi_palmos_error(sd));
		return;
	}
	palm_user = user;

	emit_begin("userWritten");
	emit_str("user", user.username, 1);
	emit_int("userId", (long)user.userID);
	emit_end();
}

/* ---- Datensätze ------------------------------------------------------- */

/* Für den Abgleich (Kalender, später Adressen, Aufgaben, Notizen) liest und
 * schreibt die App einzelne Datensätze einer Datenbank. Die Bytes eines
 * Datensatzes gehen als Hex durch die JSON-Zeilen und kommen so zurück - was
 * darin steht, wertet nur die App aus (HotSyncCore).
 *
 * Es ist immer höchstens eine Datenbank offen ("opendb"), alle
 * Datensatz-Anweisungen gelten für sie. Schlägt eine Anweisung fehl, kommt
 * "dbFailed" mit der Anweisung und dem Palm-OS-Fehler. */

static int open_db = -1;
static char open_db_name[64];

static void emit_hex(const char *key, const unsigned char *data, size_t length)
{
	static const char digits[] = "0123456789abcdef";
	size_t i;

	printf(",\"%s\":\"", key);
	for (i = 0; i < length; i++) {
		putchar(digits[data[i] >> 4]);
		putchar(digits[data[i] & 0x0F]);
	}
	putchar('"');
}

/* Hex (gerade Länge, Groß- oder Kleinbuchstaben) in Bytes. Die Länge kommt
 * in *length; -1 bei ungültigem Hex. Leerer Text = 0 Bytes. */
static int parse_hex(const char *hex, unsigned char **data, size_t *length)
{
	size_t n = strlen(hex), i;
	unsigned char *out;

	if (n % 2 != 0)
		return -1;
	out = malloc(n / 2 + 1);
	if (out == NULL)
		return -1;
	for (i = 0; i < n / 2; i++) {
		int hi, lo;
		char h = hex[2 * i], l = hex[2 * i + 1];

		hi = h >= '0' && h <= '9' ? h - '0' : h >= 'a' && h <= 'f' ? h - 'a' + 10 :
			h >= 'A' && h <= 'F' ? h - 'A' + 10 : -1;
		lo = l >= '0' && l <= '9' ? l - '0' : l >= 'a' && l <= 'f' ? l - 'a' + 10 :
			l >= 'A' && l <= 'F' ? l - 'A' + 10 : -1;
		if (hi < 0 || lo < 0) {
			free(out);
			return -1;
		}
		out[i] = (unsigned char)(hi << 4 | lo);
	}
	*data = out;
	*length = n / 2;
	return 0;
}

static void emit_db_failed(const char *op, int sd, long record_id)
{
	emit_begin("dbFailed");
	emit_str("op", op, 0);
	emit_int("error", pi_error(sd));
	emit_int("palmOSError", pi_palmos_error(sd));
	if (record_id >= 0)
		emit_int("id", record_id);
	emit_end();
}

/* Für Anweisungen, die eine offene Datenbank brauchen */
static int need_open_db(const char *op)
{
	if (open_db >= 0)
		return 1;
	emit_begin("dbFailed");
	emit_str("op", op, 0);
	emit_str("reason", "noDatabaseOpen", 0);
	emit_end();
	return 0;
}

/* "listdbs": alle Datenbanken im RAM, je eine Zeile "db", am Ende
 * "dbListFinished". Typ und Creator als Zahl (vier Zeichen, big-endian),
 * Datumsangaben als Unix-Zeit (0: nie). */
static void list_dbs(int sd)
{
	int index = 0, count = 0;
	pi_buffer_t *buffer = pi_buffer_new(sizeof(struct DBInfo));

	if (buffer == NULL) {
		emit_error("listdbs", "out of memory");
		return;
	}
	while (dlp_ReadDBList(sd, 0, dlpDBListRAM, index, buffer) >= 0) {
		struct DBInfo info;

		memcpy(&info, buffer->data, sizeof(struct DBInfo));
		index = info.index + 1;
		emit_begin("db");
		emit_str("name", info.name, 1);
		emit_int("type", (long)info.type);
		emit_int("creator", (long)info.creator);
		emit_int("flags", (long)info.flags);
		emit_int("version", (long)info.version);
		emit_int("modnum", (long)info.modnum);
		emit_int("createDate", (long)info.createDate);
		emit_int("modifyDate", (long)info.modifyDate);
		emit_int("backupDate", (long)info.backupDate);
		emit_end();
		count++;
	}
	pi_buffer_free(buffer);
	/* das Ende der Liste meldet der Palm als "nicht gefunden" */
	if (pi_palmos_error(sd) != dlpErrNotFound || !pi_socket_connected(sd)) {
		emit_db_failed("listdbs", sd, -1);
		return;
	}
	emit_begin("dbListFinished");
	emit_int("count", count);
	emit_end();
}

static void close_db(int sd)
{
	if (open_db < 0)
		return;
	dlp_CloseDB(sd, open_db);
	open_db = -1;
	open_db_name[0] = '\0';
}

/* "opendb read|write <Name>": öffnet die Datenbank, auch mit den als
 * privat markierten Datensätzen. Eine schon offene wird vorher
 * geschlossen. Meldet "dbOpened" mit der Zahl der Datensätze. */
static void open_database(int sd, const char *args)
{
	char name[64];
	int mode, handle, records = 0;

	if (strncmp(args, "read ", 5) == 0) {
		mode = dlpOpenRead | dlpOpenSecret;
		args += 5;
	} else if (strncmp(args, "write ", 6) == 0) {
		mode = dlpOpenReadWrite | dlpOpenSecret;
		args += 6;
	} else {
		emit_error("opendb", "usage: opendb read|write <name>");
		return;
	}
	close_db(sd);

	utf8_to_cp1252(args, name, sizeof(name));
	if (dlp_OpenDB(sd, 0, mode, name, &handle) < 0) {
		emit_db_failed("opendb", sd, -1);
		return;
	}
	open_db = handle;
	snprintf(open_db_name, sizeof(open_db_name), "%s", name);
	dlp_ReadOpenDBInfo(sd, handle, &records);

	emit_begin("dbOpened");
	emit_str("name", open_db_name, 1);
	emit_int("records", records);
	emit_end();
}

static void emit_record(const pi_buffer_t *buffer, recordid_t id, int index,
	int attributes, int category)
{
	emit_begin("record");
	emit_int("id", (long)id);
	emit_int("index", index);
	emit_int("attributes", attributes);
	emit_int("category", category);
	emit_hex("data", buffer->data, buffer->used);
	emit_end();
}

/* Wie oft beim Lesen nach "Abbrechen" auf dem Palm geschaut wird */
#define RECORDS_CANCEL_EVERY	16

/* "readall": jeder Datensatz der offenen Datenbank als "record", auch die
 * gelöschten und archivierten (am Attribut zu erkennen).
 * "readchanged": nur die seit dem letzten Abgleich geänderten, gelöschten
 * und archivierten. Beide enden mit "recordsFinished". */
static void read_records(int sd, int changed_only)
{
	const char *op = changed_only ? "readchanged" : "readall";
	pi_buffer_t *buffer;
	int count = 0, total = 0;

	if (!need_open_db(op))
		return;
	/* readall: so viele, wie die Datenbank meldet (wie pi_file_retrieve);
	 * readchanged: bis der Palm "nicht gefunden" meldet */
	if (changed_only ? dlp_ResetDBIndex(sd, open_db) < 0
			 : dlp_ReadOpenDBInfo(sd, open_db, &total) < 0) {
		emit_db_failed(op, sd, -1);
		return;
	}
	buffer = pi_buffer_new(0xFFFF);
	if (buffer == NULL) {
		emit_error(op, "out of memory");
		return;
	}

	while (changed_only || count < total) {
		recordid_t id = 0;
		int index = count, attributes = 0, category = 0, result;

		if (count > 0 && count % RECORDS_CANCEL_EVERY == 0 && dlp_OpenConduit(sd) < 0) {
			emit_error(op, "cancelled on the Palm or connection lost");
			pi_buffer_free(buffer);
			return;
		}
		if (changed_only)
			result = dlp_ReadNextModifiedRec(sd, open_db, buffer, &id, &index,
				&attributes, &category);
		else
			result = dlp_ReadRecordByIndex(sd, open_db, count, buffer, &id,
				&attributes, &category);
		if (result < 0) {
			/* das Ende der geänderten meldet der Palm als "nicht gefunden" */
			if (changed_only && pi_palmos_error(sd) == dlpErrNotFound
				&& pi_socket_connected(sd))
				break;
			emit_db_failed(op, sd, -1);
			pi_buffer_free(buffer);
			return;
		}
		emit_record(buffer, id, index, attributes, category);
		count++;
	}
	pi_buffer_free(buffer);

	emit_begin("recordsFinished");
	emit_int("count", count);
	emit_end();
}

/* "writerec <ID> <Attribute> <Kategorie> <Hex>": schreibt einen Datensatz.
 * ID 0 legt einen neuen an, sonst wird der mit dieser ID ersetzt (oder mit
 * ihr angelegt). Meldet "recordWritten" mit der ID, die der Palm vergeben
 * hat. */
static void write_record(int sd, const char *args)
{
	unsigned long id, attributes, category;
	recordid_t new_id = 0;
	unsigned char *data;
	size_t length;
	int consumed = 0;

	if (!need_open_db("writerec"))
		return;
	if (sscanf(args, "%lu %lu %lu %n", &id, &attributes, &category, &consumed) != 3
		|| consumed == 0 || attributes > 0xFF || category > 0x0F) {
		emit_error("writerec", "usage: writerec <id> <attributes> <category> <hex>");
		return;
	}
	if (parse_hex(args + consumed, &data, &length) < 0) {
		emit_error("writerec", "invalid hex data");
		return;
	}
	if (dlp_WriteRecord(sd, open_db, (int)attributes, (recordid_t)id, (int)category,
			data, length, &new_id) < 0) {
		emit_db_failed("writerec", sd, (long)id);
	} else {
		emit_begin("recordWritten");
		emit_int("id", (long)new_id);
		emit_int("requestedId", (long)id);
		emit_end();
	}
	free(data);
}

/* "deleterec <ID>": löscht den Datensatz endgültig */
static void delete_record(int sd, const char *args)
{
	char *end;
	unsigned long id = strtoul(args, &end, 10);

	if (!need_open_db("deleterec"))
		return;
	if (end == args || *end != '\0' || id == 0) {
		emit_error("deleterec", "usage: deleterec <id>");
		return;
	}
	if (dlp_DeleteRecord(sd, open_db, 0, (recordid_t)id) < 0) {
		emit_db_failed("deleterec", sd, (long)id);
		return;
	}
	emit_begin("recordDeleted");
	emit_int("id", (long)id);
	emit_end();
}

/* "readappinfo": der AppInfo-Block (u. a. die Kategorienamen) als
 * "appInfo"; eine Datenbank ohne Block meldet leere Daten. */
static void read_app_info(int sd)
{
	pi_buffer_t *buffer;

	if (!need_open_db("readappinfo"))
		return;
	buffer = pi_buffer_new(0xFFFF);
	if (buffer == NULL) {
		emit_error("readappinfo", "out of memory");
		return;
	}
	if (dlp_ReadAppBlock(sd, open_db, 0, -1, buffer) < 0
		&& pi_palmos_error(sd) != dlpErrNotFound) {
		emit_db_failed("readappinfo", sd, -1);
		pi_buffer_free(buffer);
		return;
	}
	emit_begin("appInfo");
	emit_hex("data", buffer->data, buffer->used);
	emit_end();
	pi_buffer_free(buffer);
}

/* "writeappinfo <Hex>": ersetzt den AppInfo-Block */
static void write_app_info(int sd, const char *hex)
{
	unsigned char *data = NULL;
	size_t length = 0;

	if (!need_open_db("writeappinfo"))
		return;
	/* leer hieße "Block entfernen" - das braucht der Abgleich nie */
	if (parse_hex(hex, &data, &length) < 0 || length == 0) {
		emit_error("writeappinfo", "invalid hex data");
		free(data);
		return;
	}
	if (dlp_WriteAppBlock(sd, open_db, data, length) < 0) {
		emit_db_failed("writeappinfo", sd, -1);
	} else {
		emit_begin("appInfoWritten");
		emit_int("bytes", (long)length);
		emit_end();
	}
	free(data);
}

/* "resetflags": nach einem gelungenen Abgleich - entfernt die gelöschten
 * und archivierten Datensätze endgültig und setzt die "geändert"-Markierung
 * aller übrigen zurück. */
static void reset_flags(int sd)
{
	if (!need_open_db("resetflags"))
		return;
	if (dlp_CleanUpDatabase(sd, open_db) < 0) {
		emit_db_failed("resetflags", sd, -1);
		return;
	}
	if (dlp_ResetSyncFlags(sd, open_db) < 0) {
		emit_db_failed("resetflags", sd, -1);
		return;
	}
	emit_begin("flagsReset");
	emit_end();
}

/* "syncinfo": mit welchem Rechner der Palm zuletzt abgeglichen hat und
 * wann. Ist es dieser Mac, genügen die geänderten Datensätze ("readchanged",
 * fast sync), sonst muss alles verglichen werden (slow sync). */
static void sync_info(void)
{
	emit_begin("syncInfo");
	emit_int("lastSyncPC", (long)palm_user.lastSyncPC);
	emit_int("lastSyncDate", (long)palm_user.lastSyncDate);
	emit_int("successfulSyncDate", (long)palm_user.successfulSyncDate);
	emit_end();
}

/* "setsyncpc <ID>": nach einem gelungenen Abgleich - dieser Mac (ID aus den
 * Einstellungen der App, nie 0) war der letzte, jetzt. */
static void set_sync_pc(int sd, const char *args)
{
	char *end;
	unsigned long id = strtoul(args, &end, 10);
	struct PilotUser user = palm_user;

	if (end == args || *end != '\0' || id == 0) {
		emit_error("setsyncpc", "usage: setsyncpc <id>");
		return;
	}
	user.lastSyncPC = id;
	user.lastSyncDate = time(NULL);
	user.successfulSyncDate = user.lastSyncDate;
	if (dlp_WriteUserInfo(sd, &user) < 0) {
		emit_error("setsyncpc", "unable to write user info (%d, PalmOS 0x%04x)",
			pi_error(sd), pi_palmos_error(sd));
		return;
	}
	palm_user = user;

	emit_begin("syncInfoWritten");
	emit_int("lastSyncPC", (long)user.lastSyncPC);
	emit_end();
}

/* Abstand der Lebenszeichen an den Palm, solange keine Anweisung kommt -
 * ohne sie bricht der Palm die Sitzung nach einer Weile ab. */
#define TICKLE_INTERVAL_MS	5000

/* Wartet, bis eine Anweisung lesbar ist, und hält den Palm solange mit
 * Lebenszeichen wach. 0, wenn der Palm nicht mehr antwortet. */
static int wait_for_command(int sd)
{
	struct pollfd in = { .fd = STDIN_FILENO, .events = POLLIN };

	for (;;) {
		int ready = poll(&in, 1, TICKLE_INTERVAL_MS);

		if (ready > 0)
			return 1;
		if (ready < 0 && errno != EINTR) {
			emit_error("command", "cannot wait for commands (%s)", strerror(errno));
			return 0;
		}
		if (ready == 0 && pi_tickle(sd) < 0) {
			emit_error("tickle", "the Palm does not answer any more");
			return 0;
		}
	}
}

/* Liest Anweisungen bis "end" oder EOF. Bei EOF (App weg) wird die
 * Sitzung trotzdem sauber beendet, damit der Palm nicht hängen bleibt. */
static void run_commands(int sd)
{
	/* Datensätze als Hex: eine Zeile kann weit über 100 KB lang sein */
	char *line = NULL;
	size_t capacity = 0;
	ssize_t length;

	/* ungepuffert: was poll() als lesbar meldet, liegt nicht schon in
	 * einem stdio-Puffer, auf den poll() nicht schaut */
	setvbuf(stdin, NULL, _IONBF, 0);

	while (wait_for_command(sd) && (length = getline(&line, &capacity, stdin)) >= 0) {
		line[strcspn(line, "\r\n")] = '\0';

		if (strncmp(line, "install ", 8) == 0) {
			install_file(sd, line + 8);
		} else if (strncmp(line, "backup ", 7) == 0) {
			backup(sd, line + 7);
		} else if (strncmp(line, "getrom ", 7) == 0) {
			get_rom(sd, line + 7);
		} else if (strncmp(line, "setuser ", 8) == 0) {
			write_user(sd, line + 8);
		} else if (strcmp(line, "listdbs") == 0) {
			list_dbs(sd);
		} else if (strncmp(line, "opendb ", 7) == 0) {
			open_database(sd, line + 7);
		} else if (strcmp(line, "closedb") == 0) {
			close_db(sd);
			emit_begin("dbClosed");
			emit_end();
		} else if (strcmp(line, "readall") == 0) {
			read_records(sd, 0);
		} else if (strcmp(line, "readchanged") == 0) {
			read_records(sd, 1);
		} else if (strncmp(line, "writerec ", 9) == 0) {
			write_record(sd, line + 9);
		} else if (strncmp(line, "deleterec ", 10) == 0) {
			delete_record(sd, line + 10);
		} else if (strcmp(line, "readappinfo") == 0) {
			read_app_info(sd);
		} else if (strncmp(line, "writeappinfo ", 13) == 0) {
			write_app_info(sd, line + 13);
		} else if (strcmp(line, "resetflags") == 0) {
			reset_flags(sd);
		} else if (strcmp(line, "syncinfo") == 0) {
			sync_info();
		} else if (strncmp(line, "setsyncpc ", 10) == 0) {
			set_sync_pc(sd, line + 10);
		} else if (strncmp(line, "log ", 4) == 0) {
			char entry[1024];
			utf8_to_cp1252(line + 4, entry, sizeof(entry));
			/* Der Palm zeigt jeden Eintrag als eigene Zeile im HotSync-Log */
			strncat(entry, "\n", sizeof(entry) - strlen(entry) - 1);
			dlp_AddSyncLogEntry(sd, entry);
		} else if (strcmp(line, "end") == 0) {
			break;
		} else if (line[0] != '\0') {
			emit_error("command", "unknown command: %.200s", line);
		}
	}
	free(line);
	/* eine offene Datenbank vor dem Ende des HotSyncs schließen */
	close_db(sd);
}

int main(int argc, char **argv)
{
	const char *port = NULL;
	int timeout = 0;
	int sd, i;

	for (i = 1; i < argc; i++) {
		if (strcmp(argv[i], "--port") == 0 && i + 1 < argc)
			port = argv[++i];
		else if (strcmp(argv[i], "--timeout") == 0 && i + 1 < argc)
			timeout = atoi(argv[++i]);
		else {
			fprintf(stderr, "usage: %s --port PORT [--timeout SECONDS]\n", argv[0]);
			return 1;
		}
	}
	if (port == NULL) {
		fprintf(stderr, "usage: %s --port PORT [--timeout SECONDS]\n", argv[0]);
		return 1;
	}

	sd = connect_palm(port, timeout);
	if (sd == -2)
		return 2;
	if (sd < 0)
		return 1;

	if (report_identity(sd) < 0) {
		pi_close(sd);
		return 1;
	}

	if (dlp_OpenConduit(sd) < 0) {
		emit_error("conduit", "cancelled on the Palm");
		pi_close(sd);
		return 1;
	}

	run_commands(sd);

	dlp_EndOfSync(sd, dlpEndCodeNormal);
	pi_close(sd);

	emit_begin("finished");
	emit_end();
	return 0;
}
