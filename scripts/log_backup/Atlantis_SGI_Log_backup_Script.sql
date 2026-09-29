/********************************************************************
 Description  : Sauvegarde du journal de transactions (LOG) de la base BD_ATLANTIS_SGI
 Version      : 2.0 - appel de Log_Database.dbo.usp_BackupDatabase
                (voir scripts/installation/02_usp_BackupDatabase.sql)
********************************************************************/

EXEC Log_Database.dbo.usp_BackupDatabase
    @DBName         = N'BD_ATLANTIS_SGI',
    @BackupType     = 'LOG',
    @BackupRoot     = N'C:\Backups\AtlantisBackup\',
    @RetentionHours = 168;        -- 7 jours (Politique de Retention.txt)
