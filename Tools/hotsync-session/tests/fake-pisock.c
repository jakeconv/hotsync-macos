/*
 * fake-pisock: just enough of libpisock to run hotsync-session without a
 * Palm. A Palm "connects" at once; it holds a user and two databases in
 * memory, "DatebookDB" with four records and an AppInfo block, and
 * "MemoDB". The record calls behave as on a Palm (DLP 1.x):
 *
 *   - records are read by index, deleted and archived ones included
 *   - ReadNextModifiedRec returns dirty, deleted and archived records, then
 *     dlpErrNotFound
 *   - WriteRecord with ID 0 creates a record with a new ID, otherwise it
 *     replaces the record with that ID (or creates it with that ID)
 *   - CleanUpDatabase removes deleted and archived records,
 *     ResetSyncFlags clears the dirty flags
 *
 * Install, backup and ROM calls fail: they are not what these tests are
 * about. Used by tests/run.sh only, never part of the app.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#include "pi-buffer.h"
#include "pi-dlp.h"
#include "pi-file.h"
#include "pi-socket.h"
#include "pi-syspkt.h"

#define PALM_SD		7
#define MAX_RECORDS	64

struct record {
	recordid_t id;
	int attributes;
	int category;
	size_t length;
	unsigned char data[65535];
};

struct database {
	const char *name;
	unsigned long type, creator;
	struct record records[MAX_RECORDS];
	int count;
	unsigned char app_info[64];
	size_t app_info_length;
	int modified_cursor;
};

static struct database databases[2];
static int databases_ready;
static struct database *open_dbs[8];
static recordid_t next_id = 0x00A00010;
static int palmos_error;
static int last_error;
static struct PilotUser user = {
	0, "Fake Palm", "", 4711, 0, 1234567, 1000000000, 1000000100
};

#define FOURCC(a, b, c, d) \
	(((unsigned long)(a) << 24) | ((unsigned long)(b) << 16) | ((unsigned long)(c) << 8) | (unsigned long)(d))

static void add_record(struct database *db, recordid_t id, int attributes, int category,
	const char *text)
{
	struct record *r = &db->records[db->count++];

	r->id = id;
	r->attributes = attributes;
	r->category = category;
	r->length = strlen(text);
	memcpy(r->data, text, r->length);
}

static void setup(void)
{
	static const unsigned char app_info[] = { 0x00, 0x01, 'U', 'n', 'f', 'i', 'l', 'e', 'd' };

	if (databases_ready)
		return;
	databases_ready = 1;

	databases[0].name = "DatebookDB";
	databases[0].type = FOURCC('D', 'A', 'T', 'A');
	databases[0].creator = FOURCC('d', 'a', 't', 'e');
	add_record(&databases[0], 0x00A00001, 0, 0, "clean");
	add_record(&databases[0], 0x00A00002, dlpRecAttrDirty, 0, "dirty");
	add_record(&databases[0], 0x00A00003, dlpRecAttrDeleted, 0, "");
	add_record(&databases[0], 0x00A00004, dlpRecAttrSecret, 2, "private");
	memcpy(databases[0].app_info, app_info, sizeof(app_info));
	databases[0].app_info_length = sizeof(app_info);

	databases[1].name = "MemoDB";
	databases[1].type = FOURCC('D', 'A', 'T', 'A');
	databases[1].creator = FOURCC('m', 'e', 'm', 'o');
}

static int ok(void)
{
	palmos_error = 0;
	last_error = 0;
	return 0;
}

static int fail(int error)
{
	palmos_error = error;
	last_error = PI_ERR_DLP_PALMOS;
	return PI_ERR_DLP_PALMOS;
}

static struct database *db_for(int handle)
{
	return handle >= 1 && handle < 8 ? open_dbs[handle] : NULL;
}

static void buffer_set(pi_buffer_t *buffer, const void *data, size_t length)
{
	if (buffer->allocated < length) {
		buffer->data = realloc(buffer->data, length);
		buffer->allocated = length;
	}
	memcpy(buffer->data, data, length);
	buffer->used = length;
}

/* ---- buffers, socket ---------------------------------------------------- */

pi_buffer_t *pi_buffer_new(size_t capacity)
{
	pi_buffer_t *buffer = calloc(1, sizeof(pi_buffer_t));

	if (buffer == NULL)
		return NULL;
	buffer->data = malloc(capacity ? capacity : 1);
	buffer->allocated = capacity;
	return buffer;
}

void pi_buffer_free(pi_buffer_t *buffer)
{
	if (buffer == NULL)
		return;
	free(buffer->data);
	free(buffer);
}

int pi_socket(int domain, int type, int protocol) { (void)domain; (void)type; (void)protocol; return 3; }
int pi_bind(int sd, const char *port) { (void)sd; (void)port; return 0; }
int pi_listen(int sd, int backlog) { (void)sd; (void)backlog; return 0; }
int pi_accept_to(int sd, struct sockaddr *addr, size_t *len, int timeout)
{
	(void)sd; (void)addr; (void)len; (void)timeout;
	setup();
	return PALM_SD;
}
int pi_close(int sd) { (void)sd; return 0; }
int pi_socket_connected(int sd) { (void)sd; return 1; }
int pi_tickle(int sd) { (void)sd; return 0; }
int pi_error(int sd) { (void)sd; return last_error; }
int pi_palmos_error(int sd) { (void)sd; return palmos_error; }

/* ---- session ------------------------------------------------------------ */

int dlp_ReadSysInfo(int sd, struct SysInfo *info)
{
	(void)sd;
	memset(info, 0, sizeof(*info));
	info->romVersion = 0x03003000;
	return ok();
}

int dlp_ReadUserInfo(int sd, struct PilotUser *u) { (void)sd; *u = user; return ok(); }

int dlp_WriteUserInfo(int sd, const struct PilotUser *u)
{
	(void)sd;
	/* like the real call: name, IDs and the last sync date */
	strcpy(user.username, u->username);
	user.userID = u->userID;
	user.viewerID = u->viewerID;
	user.lastSyncPC = u->lastSyncPC;
	user.lastSyncDate = u->lastSyncDate;
	return ok();
}

int dlp_OpenConduit(int sd) { (void)sd; return ok(); }
int dlp_EndOfSync(int sd, int status) { (void)sd; (void)status; return ok(); }
int dlp_AddSyncLogEntry(int sd, char *entry) { (void)sd; (void)entry; return ok(); }

/* ---- databases ---------------------------------------------------------- */

int dlp_ReadDBList(int sd, int cardno, int flags, int start, pi_buffer_t *list)
{
	struct DBInfo info;

	(void)sd; (void)cardno; (void)flags;
	setup();
	if (start < 0 || start >= 2)
		return fail(dlpErrNotFound);
	memset(&info, 0, sizeof(info));
	strcpy(info.name, databases[start].name);
	info.type = databases[start].type;
	info.creator = databases[start].creator;
	info.version = 1;
	info.modnum = 42;
	info.index = (unsigned int)start;
	info.createDate = 1000000000;
	info.modifyDate = 1000000500;
	info.backupDate = 0;
	buffer_set(list, &info, sizeof(info));
	return ok();
}

int dlp_OpenDB(int sd, int cardno, int mode, const char *name, int *handle)
{
	int i;

	(void)sd; (void)cardno; (void)mode;
	setup();
	for (i = 0; i < 2; i++) {
		if (strcmp(databases[i].name, name) == 0) {
			open_dbs[i + 1] = &databases[i];
			*handle = i + 1;
			return ok();
		}
	}
	return fail(dlpErrNotFound);
}

int dlp_CloseDB(int sd, int handle)
{
	(void)sd;
	if (db_for(handle) == NULL)
		return fail(dlpErrNoneOpen);
	open_dbs[handle] = NULL;
	return ok();
}

int dlp_ReadOpenDBInfo(int sd, int handle, int *records)
{
	struct database *db = db_for(handle);

	(void)sd;
	if (db == NULL)
		return fail(dlpErrNoneOpen);
	*records = db->count;
	return ok();
}

int dlp_ReadRecordByIndex(int sd, int handle, int index, pi_buffer_t *buffer,
	recordid_t *id, int *attributes, int *category)
{
	struct database *db = db_for(handle);
	struct record *r;

	(void)sd;
	if (db == NULL)
		return fail(dlpErrNoneOpen);
	if (index < 0 || index >= db->count)
		return fail(dlpErrNotFound);
	r = &db->records[index];
	buffer_set(buffer, r->data, r->length);
	*id = r->id;
	*attributes = r->attributes;
	*category = r->category;
	ok();
	return (int)r->length;
}

int dlp_ResetDBIndex(int sd, int handle)
{
	struct database *db = db_for(handle);

	(void)sd;
	if (db == NULL)
		return fail(dlpErrNoneOpen);
	db->modified_cursor = 0;
	return ok();
}

int dlp_ReadNextModifiedRec(int sd, int handle, pi_buffer_t *buffer, recordid_t *id,
	int *index, int *attributes, int *category)
{
	struct database *db = db_for(handle);

	(void)sd;
	if (db == NULL)
		return fail(dlpErrNoneOpen);
	while (db->modified_cursor < db->count) {
		int i = db->modified_cursor++;
		struct record *r = &db->records[i];

		if (r->attributes & (dlpRecAttrDirty | dlpRecAttrDeleted | dlpRecAttrArchived)) {
			buffer_set(buffer, r->data, r->length);
			*id = r->id;
			*index = i;
			*attributes = r->attributes;
			*category = r->category;
			ok();
			return (int)r->length;
		}
	}
	return fail(dlpErrNotFound);
}

int dlp_WriteRecord(int sd, int handle, int flags, recordid_t id, int category,
	const void *data, size_t length, recordid_t *new_id)
{
	struct database *db = db_for(handle);
	struct record *r = NULL;
	int i;

	(void)sd;
	if (db == NULL)
		return fail(dlpErrNoneOpen);
	if (length > sizeof(r->data))
		return fail(dlpErrParam);
	for (i = 0; id != 0 && i < db->count; i++)
		if (db->records[i].id == id)
			r = &db->records[i];
	if (r == NULL) {
		if (db->count == MAX_RECORDS)
			return fail(dlpErrMemory);
		r = &db->records[db->count++];
		r->id = id != 0 ? id : next_id++;
	}
	r->attributes = flags;
	r->category = category;
	r->length = length;
	memcpy(r->data, data, length);
	if (new_id)
		*new_id = r->id;
	return ok();
}

int dlp_DeleteRecord(int sd, int handle, int all, recordid_t id)
{
	struct database *db = db_for(handle);
	int i;

	(void)sd; (void)all;
	if (db == NULL)
		return fail(dlpErrNoneOpen);
	for (i = 0; i < db->count; i++) {
		if (db->records[i].id == id) {
			memmove(&db->records[i], &db->records[i + 1],
				(size_t)(db->count - i - 1) * sizeof(struct record));
			db->count--;
			return ok();
		}
	}
	return fail(dlpErrNotFound);
}

int dlp_ReadAppBlock(int sd, int handle, int offset, int reqbytes, pi_buffer_t *buffer)
{
	struct database *db = db_for(handle);

	(void)sd; (void)offset; (void)reqbytes;
	if (db == NULL)
		return fail(dlpErrNoneOpen);
	if (db->app_info_length == 0) {
		buffer->used = 0;
		return fail(dlpErrNotFound);
	}
	buffer_set(buffer, db->app_info, db->app_info_length);
	ok();
	return (int)db->app_info_length;
}

int dlp_WriteAppBlock(int sd, int handle, const void *data, size_t length)
{
	struct database *db = db_for(handle);

	(void)sd;
	if (db == NULL)
		return fail(dlpErrNoneOpen);
	if (length > sizeof(db->app_info))
		return fail(dlpErrParam);
	memcpy(db->app_info, data, length);
	db->app_info_length = length;
	return ok();
}

int dlp_CleanUpDatabase(int sd, int handle)
{
	struct database *db = db_for(handle);
	int i, kept = 0;

	(void)sd;
	if (db == NULL)
		return fail(dlpErrNoneOpen);
	for (i = 0; i < db->count; i++)
		if (!(db->records[i].attributes & (dlpRecAttrDeleted | dlpRecAttrArchived)))
			db->records[kept++] = db->records[i];
	db->count = kept;
	return ok();
}

int dlp_ResetSyncFlags(int sd, int handle)
{
	struct database *db = db_for(handle);
	int i;

	(void)sd;
	if (db == NULL)
		return fail(dlpErrNoneOpen);
	for (i = 0; i < db->count; i++)
		db->records[i].attributes &= ~dlpRecAttrDirty;
	return ok();
}

/* ---- not part of these tests -------------------------------------------- */

int dlp_ReadStorageInfo(int sd, int cardno, struct CardInfo *info)
{
	(void)sd; (void)cardno; (void)info;
	return fail(dlpErrNotFound);
}
int dlp_ReadFeature(int sd, unsigned long creator, int num, unsigned long *feature)
{
	(void)sd; (void)creator; (void)num; (void)feature;
	return fail(dlpErrNotFound);
}
int dlp_RPC(int sd, struct RPC_params *p, unsigned long *result)
{
	(void)sd; (void)p; (void)result;
	return fail(dlpErrNotSupp);
}
int PackRPC(struct RPC_params *p, int trap, int reply, ...)
{
	(void)p; (void)trap; (void)reply;
	return 0;
}
pi_file_t *pi_file_open(const char *name) { (void)name; return NULL; }
pi_file_t *pi_file_create(const char *name, const struct DBInfo *info) { (void)name; (void)info; return NULL; }
int pi_file_close(pi_file_t *pf) { (void)pf; return -1; }
int pi_file_retrieve(pi_file_t *pf, int sd, int cardno, progress_func progress)
{
	(void)pf; (void)sd; (void)cardno; (void)progress;
	return -1;
}
int pi_file_install(pi_file_t *pf, int sd, int cardno, progress_func progress)
{
	(void)pf; (void)sd; (void)cardno; (void)progress;
	return -1;
}
