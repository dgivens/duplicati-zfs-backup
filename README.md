# Duplicati Backup of Recursive ZFS File System Snapshots

A wrapper for performing backups using
[Duplicati](https://duplicati.readthedocs.io/en/latest/) that takes advantage of
ZFS snapshots for consistent backups of a heirarchy of ZFS file systems

## Note

While I've used Duplicati for a long time, I don't fully trust it due to the
number of times I've experienced database corruptions and the time it takes to
attempt to repair a corrupted database. I'm going to continue using it until I
find something better. I currently have my eye on
[Duplicacy](https://duplicacy.com/). These people need to get a little more
creative in their naming, though.

## Usage

### Configuration

|                                        :exclamation: Some of these values are extremely sensitive :exclamation:                                        |
| :----------------------------------------------------------------------------------------------------------------------------------------------------: |
| Duplicati targets can include credentials that grant access to a backup target and the encryption passphrase permits the decryption of the backup data |

Configs are done via environment variables. Available options are below. Those
without a default are required.

| Variable Name       | Description                                                                                                         | Default                               |
| ------------------- | ------------------------------------------------------------------------------------------------------------------- | ------------------------------------- |
| `BACKUP_NAME`       | Names are important                                                                                                 |                                       |
| `BASE_DATASET`      | Name of the dataset at the top of the file system heirarchy to backup                                               |                                       |
| `BACKUP_DEST`       | [Duplicati target address](https://duplicati.readthedocs.io/en/latest/05-storage-providers/)                        |                                       |
| `PASSPHRASE`        | Passphrase that Duplicati will use to encrypt the backup volumes                                                    |                                       |
| `CONFIG_DIR`        | Directory to look for environment files                                                                             | `/etc/duplicati-zfs-backup`           |
| `ENV_FILE`          | Path to a file containing the other environment variables definitions                                               | `${CONFIG_DIR}/${BACKUP_NAME}`        |
| `DUPLICATI_BASEDIR` | Base directory where Duplicati data for all backup jobs are located                                                 | `/opt/duplicati`                      |
| `DUPLICATI_DATADIR` | Directory containing Duplicati data for the specific backup job                                                     | `${DUPLICATI_BASEDIR}/${BACKUP_NAME}` |
| `TMP_DIR`           | Duplicati's temporary working directory for staging local copies of files and such                                  | `/var/tmp/duplicati/${BACKUP_NAME}`   |
| `DEBUG`             | Set to `1` enables command tracing and disables the script from unmounting and destroying snapshots upon completion | `0`                                   |

### Running

The script can be run directly and the backup name can be provided as an
argument

```bash
duplicati-zfs-backup.sh [name]
```

### systemd

Included are instantiated systemd service and timer units. Using the backup name
as the unit instance, you can define multiple backup jobs.

Example:

Backup name: `systems` Environment file: `/etc/duplicati-zfs-backup/systems`

```bash
systemctl enable duplicati-zfs-backup@systems.timer
systemctl start duplicati-zfs-backup@systems.timer
```

## Motivation

I've used Duplicati for some time to backup my home server remotely to Google
Drive. It has worked well enough, but I would fairly frequently get errors about
files having been changed in the middle of a backup being run. I use ZFS on most
of my Linux systems and it does snapshotting _extremely_ well. Every time I saw
the errors about file consistency, it made my teeth itch, but I wasn't able to
find a script I felt did what I really wanted.

On the surface, it seems like a pretty trivial thing. Dupicati has the ability
to run a script before and after a backup runs, so why not just create a
snapshot, backup, then destroy the snapshot? The snag is if you want to backup a
heirarchy of ZFS file systems at once.

For example, I originally setup Duplicati to backup `/export/backups`, where I
have a ZFS file system for each system that is being backed up there.

```text
NAME                             USED  AVAIL     REFER  MOUNTPOINT
storage/backups                 5.89T  47.9T     22.0G  /export/backups
storage/backups/cadia           2.46T  1.54T     1.43T  /export/backups/cadia
storage/backups/calth            728G  4.29T      585G  /export/backups/calth
storage/backups/mars            4.24G  47.9T     4.23G  /export/backups/mars
storage/backups/ryza             379G  5.63T      348G  /export/backups/ryza
storage/backups/terra            927G  47.9T      623G  /export/backups/terra
```

Each snapshot is independent of the others, so I couldn't just change my source
to `/export/backups/.zfs/snapshot/duplicati/`.

```text
❯ ls -a /export/backups/.zfs/snapshot/duplicati/ryza
.  ..
❯ ls /export/backups/ryza/.zfs/snapshot/duplicati/
ryza.sparsebundle
❯ ls /export/backups/mars/.zfs/snapshot/duplicati/
duplicity-full.20220202T000002Z.manifest.gpg
duplicity-full.20220202T000002Z.vol1.difftar.gpg
...
```

So I wasn't going to be able to just sprinkle some snapshot action on top of my
existing backup solution and get what I wanted.

Instead of using the tradition method of getting at the snapshots via the
`.zfs/snapshot` directories for each file system, I found that you can still
mount snapshots arbitrarily. I decided to still use the recursive option on
`zfs snapshot` to create a consistent set of snapshots, but then I mount each
snapshot in a heirarchy that matches the original layout under
`/export/backups`. Duplicati gets pointed at the directory where the snapshots
are mounted, and nothing has really changes from the viewpoint of Duplicati.
