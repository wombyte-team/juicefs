---
sidebar_label: Internals
sidebar_position: 4
slug: /internals
---
# JuiceFS Internals

## 1. Introduction

This article introduces the main implementation details of JuiceFS, which is used as a reference for developers to understand and contribute open source code. The content corresponds to the JuiceFS code version v1.0.0 and the metadata version V1.

## 2. Keyword Definition

- File system: i.e. JuiceFS Volume, represents a separate namespace. Files can be moved freely within the same filesystem, while data copies are required between different filesystems.
- Metadata engine: is a component that stores and manages file system metadata, usually served by a database that supports transactions. There are three categories of metadata engines currently supported by JuiceFS.
  - Redis: Redis and various protocol-compatible services
  - SQL: MySQL, PostgreSQL, SQLite, etc.
  - TKV: TiKV, BadgerDB, etc.
- Datastore: is a component used to store and manage file system data, usually served by object storage, such as Amazon S3, Aliyun OSS, etc. It can also be served by other storage systems that are compatible with object storage semantics, such as local file systems, Ceph Rados, TiKV, etc.
- Client: can be in various forms, such as mount process, S3 gateway, WebDAV server, Java SDK, etc.
- File: refers to all types of files in general in this documentation, including regular files, directory files, link files, device files, etc.
- Directory: is a special kind of file used to organize the tree structure, and its contents are an index to a set of other files.

## 3. Metadata Structure

File systems are usually organized in a tree structure, where nodes represent files and edges represent directory containment relationships. There are more than ten metadata structures in JuiceFS. Most of them are used to maintain the organization of file tree and properties of individual nodes, while the rest are used to manage system configuration, client sessions, asynchronous tasks, etc. All metadata structures are described below.

### 3.1 General Structure

#### 3.1.1 Setting

It is created when the `juicefs format` command is executed, and some of its fields can be modified later by the `juicefs config` command. The structure is specified as follows.
```go
type Format struct {
	Name             string
	UUID             string
	Storage          string
	Bucket           string
	AccessKey        string `json:",omitempty"`
	SecretKey        string `json:",omitempty"`
	SessionToken     string `json:",omitempty"`
	BlockSize        int
	Compression      string `json:",omitempty"`
	Shards           int    `json:",omitempty"`
	HashPrefix       bool   `json:",omitempty"`
	Capacity         uint64 `json:",omitempty"`
	Inodes           uint64 `json:",omitempty"`
	EncryptKey       string `json:",omitempty"`
	KeyEncrypted     bool   `json:",omitempty"`
	TrashDays        int    `json:",omitempty"`
	MetaVersion      int    `json:",omitempty"`
	MinClientVersion string `json:",omitempty"`
	MaxClientVersion string `json:",omitempty"`
}
```

- Name: name of the file system, specified by the user when formatting
- UUID: unique ID of the file system, automatically generated by the system when formatting
- Storage: short name of the object storage used to store data, such as s3, oss, etc.
- Bucket: the bucket path of the object storage
- AccessKey: access key used to access the object storage
- SecretKey: secret key used to access the object storage
- SessionToken: session token used to access the object storage, as some object storage supports the use of temporary token to obtain limited time permissions
- BlockSize: size of the data block when splitting the file (the default is 4 MiB)
- Compression: compression algorithm that is executed before uploading data blocks to the object storage (the default is no compression)
- Shards: number of buckets in the object storage, only one bucket by default; when Shards > 1, data objects will be randomly hashed into Shards buckets
- HashPrefix: whether to set a hash prefix for the object name, false by default
- Capacity: quota limit for the total capacity of the file system
- Inodes: quota limit for the total number of files in the file system
- EncryptKey: the encrypted private key of the data object, which can be used only if the data encryption function is enabled
- KeyEncrypted: whether the saved key is encrypted or not, by default the SecretKey, EncryptKey and SessionToken will be encrypted
- TrashDays: number of days the deleted files are kept in trash, the default is 1 day
- MetaVersion: the version of the metadata structure, currently V1 (V0 and V1 are the same)
- MinClientVersion: the minimum client version allowed to connect, clients earlier than this version will be denied
- MaxClientVersion: the maximum client version allowed to connect

This structure is serialized into JSON format and stored in the metadata engine.

#### 3.1.2 Counter

Maintains the value of each counter in the system and the start timestamps of some background tasks, specifically

- usedSpace: used capacity of the file system
- totalInodes: number of used files in the file system
- nextInode: the next available inode number (in Redis, the maximum inode number currently in use)
- nextChunk: the next available sliceId (in Redis, the largest sliceId currently in use)
- nextSession: the maximum sid (sessionID) currently in use
- nextTrash: the maximum trash inode number currently in use
- nextCleanupSlices: timestamp of the last check on the cleanup of residual slices
- lastCleanupSessions: timestamp of the last check on the cleanup of residual stale sessions
- lastCleanupFiles: timestamp of the last check on the cleanup of residual files
- lastCleanupTrash: timestamp of the last check on the cleanup of trash

#### 3.1.3 Session

Records the session IDs of clients connected to this file system and their timeouts. Each client sends a heartbeat message to update the timeout, and those who have not updated for a long time will be automatically cleaned up by other clients.

:::tip
Read-only clients cannot write to the metadata engine, so their sessions **will not** be recorded.
:::

#### 3.1.4 SessionInfo

Records specific metadata of the client session so that it can be viewed with the `juicefs status` command. This is specified as

```go
type SessionInfo struct {
	Version    string // JuiceFS version
	HostName   string // Host name
	MountPoint string // path to mount point. S3 gateway and WebDAV server are "s3gateway" and "webdav" respectively
	ProcessID  int    // Process ID
}
```

This structure is serialized into JSON format and stored in the metadata engine.

#### 3.1.5 Node

Records attribute information of each file, as follows

```go
type Attr struct {
	Flags     uint8  // reserved flags
	Typ       uint8  // type of a node
	Mode      uint16 // permission mode
	Uid       uint32 // owner id
	Gid       uint32 // group id of owner
	Rdev      uint32 // device number
	Atime     int64  // last access time
	Mtime     int64  // last modified time
	Ctime     int64  // last change time for meta
	Atimensec uint32 // nanosecond part of atime
	Mtimensec uint32 // nanosecond part of mtime
	Ctimensec uint32 // nanosecond part of ctime
	Nlink     uint32 // number of links (sub-directories or hardlinks)
	Length    uint64 // length of regular file

	Parent    Ino  // inode of parent; 0 means tracked by parentKey (for hardlinks)
	Full      bool // the attributes are completed or not
	KeepCache bool // whether to keep the cached page or not
}
```

There are a few fields that need clarification.

- Atime/Atimensec: set only when the file is created and when `SetAttr` is actively called, while accessing and modifying the file usually does not affect the Atime value
- Nlink
  - Directory file: initial value is 2 ('.' and '..'), add 1 for each subdirectory
  - Other files: initial value is 1, add 1 for each hard link created
- Length
  - Directory file: fixed at 4096
  - Soft link (symbolic link) file: the string length of the path to which the link points
  - Other files: the length of the actual content of the file

This structure is usually encoded in binary format and stored in the metadata engine.

#### 3.1.6 Edges

Records information on each edge in the file tree, as follows

```
parentInode, name -> type, inode
```

where parentInode is the inode number of the parent directory, and the others are the name, type, and inode number of the child files, respectively.

#### 3.1.7 LinkParent

Records the parent directory of some files. The parent directory of most files is recorded in the Parent field of the attribute; however, for files that have been created with hard links, there may be more than one parent directory, so the Parent field is set to 0, and all parent inodes are recorded independently, as follows

```
inode -> parentInode, links
```

where links is the count of the parentInode, because multiple hard links can be created in the same directory, and these hard links share one inode.

#### 3.1.8 Chunk

Records information on each Chunk, as follows

```
inode, index -> []Slices
```

where inode is the inode number of the file to which the Chunk belongs, and index is the number of all Chunks in the file, starting from 0. The Chunk value is an array of Slices. Each Slice represents a piece of data written by the client, and is appended to this array in the order of writing time. When there is an overlap between different Slices, the later Slice is used.

```go
type Slice struct {
	Pos  uint32 // offset of the Slice in the Chunk
	ID   uint64 // ID of the Slice, globally unique
	Size uint32 // size of the Slice
	Off  uint32 // offset of valid data in this Slice
	Len  uint32 // size of valid data in this Slice
}
```

This structure is encoded and saved in binary format, taking up 24 bytes.

#### 3.1.9 SliceRef

Records the reference count of a Slice, as follows

```
sliceId, size -> refs
```

Since the reference count of most Slices is 1, to reduce the number of related entries in the database, the actual value minus 1 is used as the stored count value in Redis and TKV. In this way, most of the Slices have a refs value of 0, and there is no need to create related entries in the database.

#### 3.1.10 Symlink

Records the location of the softlink file, as follows

```
inode -> target
```

#### 3.1.11 Xattr

Records extended attributes (Key-Value pairs) of a file, as follows

```
inode, key -> value
```

#### 3.1.12 Flock

Records BSD locks (flock) of a file, specifically.

```
inode, sid, owner -> ltype
```

where sid is the client session ID, owner is a string of numbers, usually associated with a process, and ltype is the lock type, which can be 'R' or 'W'.

#### 3.1.13 Plock

Record POSIX record locks (fcntl) of a file, specifically

```
inode, sid, owner -> []plockRecord
```

Here plock is a more fine-grained lock that can only lock a certain segment of the file.

```go
type plockRecord struct {
	ltype uint32 // lock type
	pid   uint32 // process ID
	start uint64 // start position of the lock
	end   uint64 // end position of the lock
}
```

This structure is encoded and stored in binary format, taking up 24 bytes.

#### 3.1.14 DelFiles

Records the list of files to be cleaned. It is needed as data cleanup of files is an asynchronous and potentially time-consuming operation that can be interrupted by other factors.

```
inode, length -> expire
```

where length is the length of the file and expire is the time when the file was deleted.

#### 3.1.15 DelSlices

Records delayed deleted Slices. When the Trash feature is enabled, old Slices deleted by the Slice Compaction will be kept for the same amount of time as the Trash configuration, to be available for data recovery if necessary.

```
sliceId, deleted -> []slice
```

where sliceId is the ID of the new slice after compaction, deleted is the timestamp of the compaction, and the mapped value is the list of all old slices that were compacted. Each slice only encodes its ID and size.

```go
type slice struct {
	ID   uint64
	Size uint32
}
```

This structure is encoded and stored in binary format, taking up 12 bytes.

#### 3.1.16 Sustained

Records the list of files that need to be kept temporarily during the session. If a file is still open when it is deleted, the data cannot be cleaned up immediately, but needs to be held temporarily until the file is closed.

```
sid -> []inode
```

where sid is the session ID and the mapped value is the list of temporarily undeleted file inodes.

### 3.2 Redis

The common format of keys in Redis is `${prefix}${JFSKey}`, where

- In standalone mode the prefix is an empty string, while in cluster mode it is a database number enclosed in curly braces, e.g. "{10}"
- JFSKey is the Key of different data structures in JuiceFS, which are listed in the subsequent subsections

In Redis Keys, integers (including inode numbers) are represented as decimal strings if not otherwise specified.

#### 3.2.1 Setting

- Key: `setting`
- Value Type: String
- Value: file system formatting information in JSON format

#### 3.2.2 Counter

- Key: counter name
- Value Type: String
- Value: value of the counter, which is actually an integer

#### 3.2.3 Session

- Key: `allSessions`
- Value Type：Sorted Set
- Value: all non-read-only sessions connected to this file system. In Set,
  - Member: session ID
  - Score: timeout point of this session

#### 3.2.4 SessionInfo

- Key: `sessionInfos`
- Value Type: Hash
- Value: basic meta-information on all non-read-only sessions. In Hash,
  - Key: session ID
  - Value: session information in JSON format

#### 3.2.5 Node

- Key: `i${inode}`
- Value Type: String
- Value: binary encoded file attribute

#### 3.2.6 Edge

- Key: `d${inode}`
- Value Type: Hash
- Value: all directory entries in this directory. In Hash,
  - Key: file name
  - Value: binary encoded file type and inode number

#### 3.2.7 LinkParent

- Key: `p${inode}`
- Value Type: Hash
- Value: all parent inodes of this file. in Hash.
  - Key: parent inode
  - Value: count of this parent inode

#### 3.2.8 Chunk

- Key: `c${inode}_${index}`
- Value Type: List
- Value: list of Slices, each Slice is binary encoded with 24 bytes

#### 3.2.9 SliceRef

- Key: `sliceRef`
- Value Type: Hash
- Value: the count value of all Slices to be recorded. In Hash,
  - Key: `k${sliceId}_${size}`
  - Value: reference count of this Slice minus 1 (if the reference count is 1, the corresponding entry is generally not created)

#### 3.2.10 Symlink

- Key: `s${inode}`
- Value Type: String
- Value: path that the symbolic link points to

#### 3.2.11 Xattr

- Key: `x${inode}`
- Value Type: Hash
- Value: all extended attributes of this file. In Hash,
  - Key: name of the extended attribute
  - Value: value of the extended attribute

#### 3.2.12 Flock

- Key: `lockf${inode}`
- Value Type: Hash
- Value: all flocks of this file. In Hash,
  - Key: `${sid}_${owner}`, owner in hexadecimal
  - Value: lock type, can be 'R' or 'W'

#### 3.2.13 Plock

- Key: `lockp${inode}`
- Value Type: Hash
- Value: all plocks of this file. In Hash,
  - Key: `${sid}_${owner}`, owner in hexadecimal
  - Value: array of bytes, where every 24 bytes corresponds to a [plockRecord](#3.1.13-Plock)

#### 3.2.14 DelFiles

- Key：`delfiles`
- Value Type：Sorted Set
- Value: list of all files to be cleaned. In Set,
  - Member: `${inode}:${length}`
  - Score: the timestamp when this file was added to the set

#### 3.2.15 DelSlices

- Key: `delSlices`
- Value Type: Hash
- Value: all Slices to be cleaned. In Hash,
  - Key: `${sliceId}_${deleted}`
  - Value: array of bytes, where every 12 bytes corresponds to a [slice](#3.1.15-DelSlices)

#### 3.2.16 Sustained

- Key: `session${sid}`
- Value Type: List
- Value: list of files temporarily reserved in this session. In List,
  - Member: inode number of the file

### 3.3 SQL

Metadata is stored in different tables by type, and each table is named with `jfs_` followed by its specific structure name to form the table name, e.g. `jfs_node`. Some tables use `Id` with the `bigserial` type as primary keys to ensure that each table has a primary key, and the `Id` columns do not contain actual information.

#### 3.3.1 Setting

```go
type setting struct {
	Name  string `xorm:"pk"`
	Value string `xorm:"varchar(4096) notnull"`
}
```

There is only one entry in this table with "format" as Name and file system formatting information in JSON as Value.

#### 3.3.2 Counter

```go
type counter struct {
	Name  string `xorm:"pk"`
	Value int64  `xorm:"notnull"`
}
```

#### 3.3.3 Session

```go
type session2 struct {
	Sid    uint64 `xorm:"pk"`
	Expire int64  `xorm:"notnull"`
	Info   []byte `xorm:"blob"`
}
```

#### 3.3.4 SessionInfo

There is no separate table for this, but it is recorded in the `Info` column of `session2`.

#### 3.3.5 Node

```go
type node struct {
	Inode  Ino    `xorm:"pk"`
	Type   uint8  `xorm:"notnull"`
	Flags  uint8  `xorm:"notnull"`
	Mode   uint16 `xorm:"notnull"`
	Uid    uint32 `xorm:"notnull"`
	Gid    uint32 `xorm:"notnull"`
	Atime  int64  `xorm:"notnull"`
	Mtime  int64  `xorm:"notnull"`
	Ctime  int64  `xorm:"notnull"`
	Nlink  uint32 `xorm:"notnull"`
	Length uint64 `xorm:"notnull"`
	Rdev   uint32
	Parent Ino
}
```

Most of the fields are the same as [Attr](#3.1.5-Node), but the timestamp precision is lower, i.e., Atime/Mtime/Ctime are in microseconds.

#### 3.3.6 Edge

```go
type edge struct {
	Id     int64  `xorm:"pk bigserial"`
	Parent Ino    `xorm:"unique(edge) notnull"`
	Name   []byte `xorm:"unique(edge) varbinary(255) notnull"`
	Inode  Ino    `xorm:"index notnull"`
	Type   uint8  `xorm:"notnull"`
}
```

#### 3.3.7 LinkParent

There is no separate table for this. All `Parent`s are found based on the `Inode` index in `edge`.

#### 3.3.8 Chunk

```go
type chunk struct {
	Id     int64  `xorm:"pk bigserial"`
	Inode  Ino    `xorm:"unique(chunk) notnull"`
	Indx   uint32 `xorm:"unique(chunk) notnull"`
	Slices []byte `xorm:"blob notnull"`
}
```

Slices are an array of bytes, and each [Slice](#3.1.8-chunk) corresponds to 24 bytes.

#### 3.3.9 SliceRef

```go
type sliceRef struct {
	Id   uint64 `xorm:"pk chunkid"`
	Size uint32 `xorm:"notnull"`
	Refs int    `xorm:"notnull"`
}
```

#### 3.3.10 Symlink

```go
type symlink struct {
	Inode  Ino    `xorm:"pk"`
	Target []byte `xorm:"varbinary(4096) notnull"`
}
```

#### 3.3.11 Xattr

```go
type xattr struct {
	Id    int64  `xorm:"pk bigserial"`
	Inode Ino    `xorm:"unique(name) notnull"`
	Name  string `xorm:"unique(name) notnull"`
	Value []byte `xorm:"blob notnull"`
}
```

#### 3.3.12 Flock

```go
type flock struct {
	Id    int64  `xorm:"pk bigserial"`
	Inode Ino    `xorm:"notnull unique(flock)"`
	Sid   uint64 `xorm:"notnull unique(flock)"`
	Owner int64  `xorm:"notnull unique(flock)"`
	Ltype byte   `xorm:"notnull"`
}
```

#### 3.3.13 Plock

```go
type plock struct {
	Id      int64  `xorm:"pk bigserial"`
	Inode   Ino    `xorm:"notnull unique(plock)"`
	Sid     uint64 `xorm:"notnull unique(plock)"`
	Owner   int64  `xorm:"notnull unique(plock)"`
	Records []byte `xorm:"blob notnull"`
}
```

Records is an array of bytes, and each [plockRecord](#3.1.13-Plock) corresponds to 24 bytes.

#### 3.3.14 DelFiles

```go
type delfile struct {
	Inode  Ino    `xorm:"pk notnull"`
	Length uint64 `xorm:"notnull"`
	Expire int64  `xorm:"notnull"`
}
```

#### 3.3.15 DelSlices

```go
type delslices struct {
	Id      uint64 `xorm:"pk chunkid"`
	Deleted int64  `xorm:"notnull"`
	Slices  []byte `xorm:"blob notnull"`
}
```

Slices is an array of bytes, and each [slice](#3.1.15-DelSlices) corresponds to 12 bytes.

#### 3.3.16 Sustained

```go
type sustained struct {
	Id    int64  `xorm:"pk bigserial"`
	Sid   uint64 `xorm:"unique(sustained) notnull"`
	Inode Ino    `xorm:"unique(sustained) notnull"`
}
```

### 3.4 TKV

The common format of keys in TKV (Transactional Key-Value Database) is `${prefix}${JFSKey}`, where

- prefix is used to distinguish between different file systems, usually `${VolumeName}0xFD`, where `0xFD` is used as a special byte to handle cases when there is an inclusion relationship between different file system names. In addition, for databases that are not shareable (e.g. BadgerDB), the empty string is used as prefix.
- JFSKey is the JuiceFS Key for different data types, which is listed in the following subsections.

In TKV's Keys, all integers are stored in encoded binary form.

- inode and counter value occupy 8 bytes and are encoded with **small endian**.
- sid, sliceId and timestamp occupy 8 bytes and are encoded with **big endian**.

#### 3.4.1 Setting

```
setting -> file system formatting information in JSON format
```

#### 3.4.2 Counter

```
C${name} -> counter value
```

#### 3.4.3 Session

```
SE${sid} -> timestamp
```

#### 3.4.4 SessionInfo

```
SI${sid} -> session information in JSON format
```

#### 3.4.5 Node

```
A${inode}I -> encoded Attr
```

#### 3.4.6 Edge

```
A${inode}D${name} -> encoded {type, inode}
```

#### 3.4.7 LinkParent

```
A${inode}P${parentInode} -> counter value
```

#### 3.4.8 Chunk

```
A${inode}C${index} -> Slices
```

where index takes up 4 bytes and is encoded with **big endian**. Slices is an array of bytes, one [Slice](#3.1.8-Chunk) per 24 bytes.

#### 3.4.9 SliceRef

```
K${sliceId}${size} -> counter value
```

where size takes up 4 bytes and is encoded with **big endian**.

#### 3.4.10 Symlink

```
A${inode}S -> target
```

#### 3.4.11 Xattr

```
A${inode}X${name} -> xattr value
```

#### 3.4.12 Flock

```
F${inode} -> flocks
```

where flocks is an array of bytes, one flock per 17 bytes.

```go
type flock struct {
	sid   uint64
	owner uint64
	ltype uint8
}
```

#### 3.4.13 Plock

```
P${inode} -> plocks
```

where plocks is an array of bytes and the corresponding plock is variable-length.

```go
type plock struct {
	sid 	uint64
	owner 	uint64
	size 	uint32
	records []byte
}
```

where size is the length of the records array and every 24 bytes in records corresponds to one [plockRecord](#3.1.13-Plock).

#### 3.4.14 DelFiles

```
D${inode}${length} -> timestamp
```

where length takes up 8 bytes and is encoded with **big endian**.

#### 3.4.15 DelSlices

```
L${timestamp}${sliceId} -> slices
```

where slices is an array of bytes, and one [slice](#3.1.15-DelSlices) corresponds to 12 bytes.

#### 3.4.16 Sustained

```
SS${sid}${inode} -> 1
```

Here the Value value is only used as a placeholder.

## 4 File Data Format

### 4.1 Finding files by path

According to the design of [Edge](# 3.1.6-Edge), only the direct children of each directory are recorded in the metadata engine. When an application provides a path to access a file, JuiceFS needs to look it up level by level. Now suppose the application wants to open the file `/dir1/dir2/testfile`, then it needs to

1. search for the entry with name "dir1" in the Edge structure of the root directory (inode number is fixed to 1) and get its inode number N1
2. search for the entry with the name "dir2" in the Edge structure of N1 and get its inode number N2
3. search for the entry with the name "testfile" in the Edge structure of N2, and get its inode number N3
4. search for the [Node](#3.1.5-Node) structure corresponding to N3 to get the attributes of the file

Failure in any of the above steps will result in the file pointed to by that path not being found.

### 4.2 File data splitting

From the previous section, we know how to find the file based on its path and get its attributes. The metadata related to the contents of the file can be found based on the inode and size fields in the file properties. Now suppose a file has an inode of 100 and a size of 160 MiB, then the file has `(size-1) / 64 MiB + 1 = 3` Chunks, as follows.

```
 File: |_ _ _ _ _ _ _ _ _ _ _ _ _ _ _ _|_ _ _ _ _ _ _ _ _ _ _ _ _ _ _ _|_ _ _ _ _ _ _ _|
Chunk: |<---        Chunk 0        --->|<---        Chunk 1        --->|<-- Chunk 2 -->|
```

In standalone Redis, this means that there are 3 [Chunk Keys](#3.1.8-Chunk), i.e.,`c100_0`, `c100_1` and `c100_2`, each corresponding to a list of Slices. These Slices are mainly generated when the data is written and may overwrite each other or may not fill the Chunk completely, so you need to traverse this list of Slices sequentially and reconstruct the latest version of the data distribution before using it, so that

1. the part covered by more than one Slice is based on the last added Slice
2. the part that is not covered by Slice is automatically zeroed, and is represented by sliceId = 0
3. truncate Chunk according to file size

Now suppose there are 3 Slices in Chunk 0

```go
Slice{pos: 10M, id: 10, size: 30M, off: 0, len: 30M}
Slice{pos: 20M, id: 11, size: 16M, off: 0, len: 16M}
Slice{pos: 16M, id: 12, size: 10M, off: 0, len: 10M}
```

It can be illustrated as follows (each '_' denotes 2 MiB)

```
   Chunk: |_ _ _ _ _ _ _ _ _ _ _ _ _ _ _ _ _ _ _ _ _ _ _ _ _ _ _ _ _ _ _ _|
Slice 10:           |_ _ _ _ _ _ _ _ _ _ _ _ _ _ _|
Slice 11:                     |_ _ _ _ _ _ _ _|
Slice 12:                 |_ _ _ _ _|

New List: |_ _ _ _ _|_ _ _|_ _ _ _ _|_ _ _ _ _|_ _|_ _ _ _ _ _ _ _ _ _ _ _|
               0      10      12         11    10             0
```

The reconstructed new list contains and only contains the latest data distribution for this Chunk as follows
```go
Slice{pos:   0, id:  0, size: 10M, off:   0, len: 10M}
Slice{pos: 10M, id: 10, size: 30M, off:   0, len:  6M}
Slice{pos: 16M, id: 12, size: 10M, off:   0, len: 10M}
Slice{pos: 26M, id: 11, size: 16M, off:  6M, len: 10M}
Slice{pos: 36M, id: 10, size: 30M, off: 26M, len:  4M}
Slice{pos: 40M, id:  0, size: 24M, off:   0, len: 24M} // can be ommited
```

### 4.3 Data objects

#### 4.3.1 Object naming

Block is the basic unit for JuiceFS to manage data. Its size is 4 MiB by default, and can be changed only when formatting a file system, within the interval [64 KiB, 16 MiB]. Each Block is an object in the object storage after upload, and is named in the format `${fsname}/chunks/${hash}/${basename}`, where

- fsname is the file system name
- "chunks" is a fixed string representing the data object of JuiceFS
- hash is the hash value calculated from basename, which plays a role in isolation management
- basename is the valid name of the object in the format of `${sliceId}_${index}_${size}`, where
  - sliceId is the ID of the Slice to which the object belongs, and each Slice in JuiceFS has a globally unique ID
  - index is the index of the object in the Slice it belongs to, by default a Slice can be split into at most 16 Blocks, so its value range is [0, 16)
  - size is the size of the Block, and by default it takes the value of (0, 4 MiB]

Currently there are two hash algorithms, and both use the sliceId in basename as the parameter. Which algorithm will be chosen to use follows the [HashPrefix](#3.1.1-Setting) of the file system.

```go
func hash(sliceId int) string {
	if HashPrefix {
		return fmt.Sprintf("%02X/%d", sliceId%256, sliceId/1000/1000)
	}
	return fmt.Sprintf("%d/%d", sliceId/1000/1000, sliceId/1000)
}
```

Suppose a file system named `jfstest` is written with a continuous 10 MiB of data and internally given a SliceID of 1 with HashPrefix disabled, then the following three objects will be generated in the object storage.

```
jfstest/chunks/0/0/1_0_4194304
jfstest/chunks/0/0/1_1_4194304
jfstest/chunks/0/0/1_2_2097152
```

Similarly, now taking the 64 MiB chunk in the previous section as an example, its actual data distribution is as follows

```
 0 ~ 10M: Zero
10 ~ 16M: 10_0_4194304, 10_1_4194304(0 ~ 2M)
16 ~ 26M: 12_0_4194304, 12_1_4194304, 12_2_2097152
26 ~ 36M: 11_1_4194304(2 ~ 4M), 11_2_4194304, 11_3_4194304
36 ~ 40M: 10_6_4194304(2 ~ 4M), 10_7_2097152
40 ~ 64M: Zero
```

According to this, the client can quickly find the data needed for the application. For example, reading 8 MiB data at offset 10 MiB location will involve 3 objects, as follows

- Read the entire object from `10_0_4194304`, corresponding to 0 to 4 MiB of the read data
- Read 0 to 2 MiB from `10_1_4194304`, corresponding to 4 to 6 MiB of the read data
- Read 0 to 2 MiB from `12_0_4194304`, corresponding to 6 to 8 MiB of the read data

To facilitate obtaining the list of objects of a certain file, JuiceFS provides the `info` command, e.g. `juicefs info /mnt/jfs/test.tmp`.

```bash
objects:
+------------+---------------------------------+----------+---------+----------+
| chunkIndex |            objectName           |   size   |  offset |  length  |
+------------+---------------------------------+----------+---------+----------+
|          0 |                                 | 10485760 |       0 | 10485760 |
|          0 | jfstest/chunks/0/0/10_0_4194304 |  4194304 |       0 |  4194304 |
|          0 | jfstest/chunks/0/0/10_1_4194304 |  4194304 |       0 |  2097152 |
|          0 | jfstest/chunks/0/0/12_0_4194304 |  4194304 |       0 |  4194304 |
|          0 | jfstest/chunks/0/0/12_1_4194304 |  4194304 |       0 |  4194304 |
|          0 | jfstest/chunks/0/0/12_2_2097152 |  2097152 |       0 |  2097152 |
|          0 | jfstest/chunks/0/0/11_1_4194304 |  4194304 | 2097152 |  2097152 |
|          0 | jfstest/chunks/0/0/11_2_4194304 |  4194304 |       0 |  4194304 |
|          0 | jfstest/chunks/0/0/11_3_4194304 |  4194304 |       0 |  4194304 |
|          0 | jfstest/chunks/0/0/10_6_4194304 |  4194304 | 2097152 |  2097152 |
|          0 | jfstest/chunks/0/0/10_7_2097152 |  2097152 |       0 |  2097152 |
|        ... |                             ... |      ... |     ... |      ... |
+------------+---------------------------------+----------+---------+----------+
```

The empty objectName in the table means a file hole and is read as 0. As you can see, the output is consistent with the previous analysis.

It is worth mentioning that the 'size' here is size of the original data in the Block, rather than that of the actual object in object storage. The original data is written directly to object storage by default, so the 'size' is equal to object size. However, when data compression or data encryption is enabled, the size of the actual object will change and may no longer be the same as the 'size'.

#### 4.3.2 Data compression

You can configure the compression algorithm (supporting lz4 and zstd) with the `--compress <value>` parameter when formatting a file system, so that all data blocks of this file system will be compressed before uploading to object storage. The object name remains the same as default, and the content is the result of the compression algorithm, without any other meta information. Therefore, the compression algorithm in the [file system formatting Information](#3.1.1-Setting) is not allowed to be modified, otherwise it will cause the failure of reading existing data.

#### 4.3.3 Data encryption

The RSA private key can be configured to enable [static data encryption](https://juicefs.com/docs/community/security/encrypt/) when formatting a file system with the `--encrypt-rsa-key <value>` parameter, which allows all data blocks of this file system to be encrypted before uploading to the object storage. The object name is still the same as default, while its content becomes a header plus the result of the data encryption algorithm. The header contains a random seed and the symmetric key used for decryption, and the symmetric key itself is encrypted with the RSA private key. Therefore, it is not allowed to modify the RSA private key in the [file system formatting Information](#3.1.1-Setting), otherwise reading existing data will fail.

:::note
If both compression and encryption are enabled, the original data will be compressed and then encrypted before uploading to the object storage.
:::