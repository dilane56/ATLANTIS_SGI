/********************************************************************
 Description  : Sauvegarde complète (FULL) de la base BD_ATLANTIS_SGI
 Version      : 2.0 - appel de Log_Database.dbo.usp_BackupDatabase
                (voir scripts/installation/02_usp_BackupDatabase.sql)
********************************************************************/

EXEC Log_Database.dbo.usp_BackupDatabase
    @DBName         = N'BD_ATLANTIS_SGI',
    @BackupType     = 'FULL',
    @BackupRoot     = N'C:\Backups\AtlantisBackup\',
    @CopyOnly       = 0,          -- 1 = sauvegarde ponctuelle hors planning (COPY_ONLY, sans purge)
    @RetentionHours = 552;        -- 23 jours (Politique de Retention.txt)
