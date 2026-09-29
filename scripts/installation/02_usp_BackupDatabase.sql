/********************************************************************
 Description  : Procédure de sauvegarde FULL / DIFF / LOG avec
                contrôles préalables, vérification, journalisation
                et purge des fichiers selon la politique de rétention.
 Base         : Log_Database
 Ordre        : 2/3 (après 01_Log_Database.sql)
 Version      : 2.0

 Arborescence produite :
    @BackupRoot\FULL\<Base>_yyyyMMdd_HHmmss_FULL.bak
    @BackupRoot\DIFF\<Base>_yyyyMMdd_HHmmss_DIFF.bak
    @BackupRoot\LOG\<Base>_yyyyMMdd_HHmmss_LOG.trn

 Exemple :
    EXEC Log_Database.dbo.usp_BackupDatabase
        @DBName = N'BD_ATLANTIS_SGI', @BackupType = 'FULL',
        @BackupRoot = N'C:\Backups\AtlantisBackup\', @RetentionHours = 552;
********************************************************************/

USE [Log_Database];
GO

CREATE OR ALTER PROCEDURE dbo.usp_BackupDatabase
    @DBName         SYSNAME,
    @BackupType     VARCHAR(4),         -- 'FULL' | 'DIFF' | 'LOG'
    @BackupRoot     NVARCHAR(256),      -- dossier racine, contient FULL\, DIFF\, LOG\
    @CopyOnly       BIT = 0,            -- 1 = FULL ponctuelle hors planning (COPY_ONLY, pas de purge)
    @RetentionHours INT = NULL          -- durée de conservation ; NULL = pas de purge
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @BackupPath NVARCHAR(256);
    DECLARE @Extension NVARCHAR(3);
    DECLARE @FileName NVARCHAR(500);
    DECLARE @LogBackupType NVARCHAR(20);

    DECLARE @StartTime DATETIME = GETDATE();
    DECLARE @EndTime DATETIME;
    DECLARE @Duration INT;
    DECLARE @ErrorNumber INT;
    DECLARE @ErrorMessage NVARCHAR(4000);
    DECLARE @LogId INT;

    DECLARE @BackupSizeMB DECIMAL(18,2);
    DECLARE @CompressedSizeMB DECIMAL(18,2);
    DECLARE @LastFullStart DATETIME;
    DECLARE @PurgeCutoff DATETIME;
    DECLARE @PurgeCutoffText NVARCHAR(19);
    DECLARE @PurgeInfo NVARCHAR(4000);

    --------------------------------------------------------
    -- Validation des paramètres
    --------------------------------------------------------

    IF @BackupType NOT IN ('FULL','DIFF','LOG')
    BEGIN
        ;THROW 50000, 'Paramètre @BackupType invalide : valeurs possibles FULL, DIFF, LOG.', 1;
    END;

    IF @CopyOnly = 1 AND @BackupType <> 'FULL'
    BEGIN
        ;THROW 50000, 'Le paramètre @CopyOnly n''est prévu que pour une sauvegarde FULL.', 1;
    END;

    --------------------------------------------------------
    -- Construction du nom du fichier
    -- (format yyyyMMdd_HHmmss : tri chronologique = tri alphabétique)
    --------------------------------------------------------

    IF RIGHT(@BackupRoot, 1) <> '\'
        SET @BackupRoot += '\';

    SET @BackupPath = @BackupRoot + @BackupType + '\';
    SET @Extension = CASE WHEN @BackupType = 'LOG' THEN 'trn' ELSE 'bak' END;
    SET @FileName = @BackupPath + @DBName + '_' + FORMAT(@StartTime, 'yyyyMMdd_HHmmss')
                  + '_' + @BackupType + '.' + @Extension;

    SET @LogBackupType = CASE
                            WHEN @BackupType = 'DIFF' THEN 'DIFFERENTIAL'
                            WHEN @CopyOnly = 1 THEN 'FULL_COPY_ONLY'
                            ELSE @BackupType
                         END;

    --------------------------------------------------------
    -- Journalisation : début
    -- (ne doit jamais empêcher la sauvegarde)
    --------------------------------------------------------

    BEGIN TRY
        INSERT INTO dbo.BackupExecutionLog (DatabaseName, BackupType, BackupFile, StartTime, Status)
        VALUES (@DBName, @LogBackupType, @FileName, @StartTime, 'RUNNING');

        SET @LogId = SCOPE_IDENTITY();
    END TRY
    BEGIN CATCH
        PRINT 'Avertissement : journalisation indisponible - ' + ERROR_MESSAGE();
    END CATCH;

    BEGIN TRY

        PRINT 'Début de la sauvegarde ' + @LogBackupType + ' de ' + @DBName + ' : ' + CONVERT(VARCHAR, @StartTime, 120);

        ----------------------------------------------------
        -- Contrôles préalables
        ----------------------------------------------------

        IF NOT EXISTS (SELECT 1 FROM sys.databases WHERE name = @DBName AND state_desc = 'ONLINE')
        BEGIN
            SET @ErrorMessage = 'La base ' + @DBName + ' n''existe pas ou n''est pas en ligne.';
            THROW 50001, @ErrorMessage, 1;
        END;

        -- Une différentielle exige une sauvegarde FULL de base
        -- (differential_base_lsn est NULL tant qu'aucune FULL n'a été faite)
        IF @BackupType = 'DIFF'
            AND EXISTS (SELECT 1 FROM sys.master_files
                        WHERE database_id = DB_ID(@DBName)
                          AND file_id = 1
                          AND differential_base_lsn IS NULL)
        BEGIN
            SET @ErrorMessage = 'Aucune sauvegarde FULL de base pour ' + @DBName + ' : sauvegarde différentielle impossible.';
            THROW 50002, @ErrorMessage, 1;
        END;

        IF @BackupType = 'LOG'
        BEGIN
            -- La sauvegarde du journal exige le mode de récupération FULL ou BULK_LOGGED
            IF NOT EXISTS (SELECT 1 FROM sys.databases
                           WHERE name = @DBName
                             AND recovery_model_desc IN ('FULL','BULK_LOGGED'))
            BEGIN
                SET @ErrorMessage = 'La base ' + @DBName + ' n''est pas en mode de récupération FULL / BULK_LOGGED.';
                THROW 50003, @ErrorMessage, 1;
            END;

            -- Une sauvegarde FULL doit avoir initialisé la chaîne des journaux
            IF EXISTS (SELECT 1 FROM sys.database_recovery_status
                       WHERE database_id = DB_ID(@DBName)
                         AND last_log_backup_lsn IS NULL)
            BEGIN
                SET @ErrorMessage = 'Aucune sauvegarde FULL n''a initialisé la chaîne des journaux de ' + @DBName + '.';
                THROW 50004, @ErrorMessage, 1;
            END;
        END;

        -- Création du dossier de destination s'il n'existe pas
        EXEC master.dbo.xp_create_subdir @BackupPath;

        ----------------------------------------------------
        -- Sauvegarde
        ----------------------------------------------------

        IF @BackupType = 'FULL' AND @CopyOnly = 1
            BACKUP DATABASE @DBName TO DISK = @FileName
            WITH COPY_ONLY, INIT, COMPRESSION, CHECKSUM, STATS = 10;
        ELSE IF @BackupType = 'FULL'
            BACKUP DATABASE @DBName TO DISK = @FileName
            WITH INIT, COMPRESSION, CHECKSUM, STATS = 10;
        ELSE IF @BackupType = 'DIFF'
            BACKUP DATABASE @DBName TO DISK = @FileName
            WITH DIFFERENTIAL, INIT, COMPRESSION, CHECKSUM, STATS = 10;
        ELSE
            BACKUP LOG @DBName TO DISK = @FileName
            WITH INIT, COMPRESSION, CHECKSUM, STATS = 10;

        ----------------------------------------------------
        -- Vérification de la sauvegarde
        ----------------------------------------------------

        RESTORE VERIFYONLY FROM DISK = @FileName WITH CHECKSUM;

        SELECT TOP (1)
            @BackupSizeMB     = bs.backup_size / 1048576.0,
            @CompressedSizeMB = bs.compressed_backup_size / 1048576.0
        FROM msdb.dbo.backupset AS bs
        JOIN msdb.dbo.backupmediafamily AS mf ON mf.media_set_id = bs.media_set_id
        WHERE mf.physical_device_name = @FileName
        ORDER BY bs.backup_set_id DESC;

        ----------------------------------------------------
        -- Purge des anciens fichiers du même type
        -- Garde-fou : on ne supprime jamais un fichier postérieur
        -- à la dernière FULL (la chaîne de restauration courante
        -- reste complète même si les FULL échouent plusieurs jours).
        ----------------------------------------------------

        IF @RetentionHours IS NOT NULL AND @CopyOnly = 0
        BEGIN
            BEGIN TRY
                SET @PurgeCutoff = DATEADD(HOUR, -@RetentionHours, @StartTime);

                SELECT @LastFullStart = MAX(backup_start_date)
                FROM msdb.dbo.backupset
                WHERE database_name = @DBName
                  AND type = 'D'
                  AND is_copy_only = 0;

                IF @LastFullStart IS NOT NULL AND @PurgeCutoff > DATEADD(MINUTE, -1, @LastFullStart)
                    SET @PurgeCutoff = DATEADD(MINUTE, -1, @LastFullStart);

                SET @PurgeCutoffText = CONVERT(NVARCHAR(19), @PurgeCutoff, 126);

                EXEC master.sys.xp_delete_file 0, @BackupPath, @Extension, @PurgeCutoffText, 0;

                SET @PurgeInfo = 'Fichiers .' + @Extension + ' antérieurs au '
                               + CONVERT(NVARCHAR(19), @PurgeCutoff, 120) + ' supprimés de ' + @BackupPath;
            END TRY
            BEGIN CATCH
                SET @PurgeInfo = 'Échec de la purge : ' + ERROR_MESSAGE();
            END CATCH;

            PRINT @PurgeInfo;
        END;

        ----------------------------------------------------
        -- Fin
        ----------------------------------------------------

        SET @EndTime = GETDATE();
        SET @Duration = DATEDIFF(SECOND, @StartTime, @EndTime);

        IF @LogId IS NOT NULL
        BEGIN
            BEGIN TRY
                UPDATE dbo.BackupExecutionLog
                SET EndTime          = @EndTime,
                    DurationSeconds  = @Duration,
                    Status           = 'SUCCESS',
                    BackupSizeMB     = @BackupSizeMB,
                    CompressedSizeMB = @CompressedSizeMB,
                    PurgeInfo        = @PurgeInfo
                WHERE Id = @LogId;
            END TRY
            BEGIN CATCH
                PRINT 'Avertissement : mise à jour du log impossible - ' + ERROR_MESSAGE();
            END CATCH;
        END;

        PRINT 'Sauvegarde terminée avec succès : ' + @FileName;
        PRINT 'Durée : ' + CAST(@Duration AS VARCHAR) + ' secondes';

    END TRY
    BEGIN CATCH

        SET @EndTime = GETDATE();
        SET @Duration = DATEDIFF(SECOND, @StartTime, @EndTime);
        SET @ErrorNumber = ERROR_NUMBER();
        SET @ErrorMessage = ERROR_MESSAGE();

        IF @LogId IS NOT NULL
        BEGIN
            BEGIN TRY
                UPDATE dbo.BackupExecutionLog
                SET EndTime         = @EndTime,
                    DurationSeconds = @Duration,
                    Status          = 'FAILED',
                    ErrorNumber     = @ErrorNumber,
                    ErrorMessage    = @ErrorMessage
                WHERE Id = @LogId;
            END TRY
            BEGIN CATCH
                PRINT 'Avertissement : mise à jour du log impossible - ' + ERROR_MESSAGE();
            END CATCH;
        END;

        PRINT 'Erreur ' + CAST(@ErrorNumber AS VARCHAR(10)) + ' : ' + @ErrorMessage;

        THROW;

    END CATCH;
END;
GO
