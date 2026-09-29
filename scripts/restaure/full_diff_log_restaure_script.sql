USE master;
GO

ALTER DATABASE [cliniquedb] SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
GO

-- 1. Étape 1 : Restaurer la sauvegarde FULL avec NORECOVERY
RESTORE DATABASE [cliniquedb]
FROM DISK = 'C:\Backups\CliniqueBackup\cliniquedb_FULL.bak'
WITH NORECOVERY, REPLACE;
GO

-- 2. Étape 2 : Restaurer la dernière Sauvegarde Différentielle avec NORECOVERY
RESTORE DATABASE [cliniquedb]
FROM DISK = 'C:\Backups\CliniqueBackup\cliniquedb_DIFF.bak'
WITH NORECOVERY;
GO

-- 3. Étape 3 : Restaurer le ou les Journaux de transactions (Logs) avec NORECOVERY
RESTORE LOG [cliniquedb]
FROM DISK = 'C:\Backups\CliniqueBackup\cliniquedb_LOG1.trn'
WITH NORECOVERY;
GO

-- 4. Étape Finale : Appliquer le tout dernier Log ET finaliser avec RECOVERY
RESTORE LOG [cliniquedb]
FROM DISK = 'C:\Backups\CliniqueBackup\cliniquedb_LOG_dernier.trn'
WITH RECOVERY;
GO

ALTER DATABASE [cliniquedb] SET MULTI_USER;
GO