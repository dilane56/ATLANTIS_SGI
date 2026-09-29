/********************************************************************
 Description  : Sauvegarde différentielle de la base BD_ATLANTIS_SGI
 Version      : 1.0
********************************************************************/

DECLARE @BackupPath NVARCHAR(256) = 'C:\Backups\AtlantisBackup\DIFF\';
DECLARE @DBName NVARCHAR(128) = 'BD_ATLANTIS_SGI';
DECLARE @FileName NVARCHAR(500);
DECLARE @FileDate NVARCHAR(30);

DECLARE @StartTime DATETIME;
DECLARE @EndTime DATETIME;
DECLARE @Duration INT;
DECLARE @ErrorMessage NVARCHAR(MAX);

DECLARE @LogId INT;

--------------------------------------------------------
-- Construction du nom du fichier
--------------------------------------------------------

SET @FileDate = FORMAT(GETDATE(),'dd-MM-yyyy_HH''H''mm''M''ss''S''');

SET @FileName =
@BackupPath +
@DBName +
'_' +
@FileDate +
'_Diff.bak';

--------------------------------------------------------
-- Heure de début
--------------------------------------------------------

SET @StartTime = GETDATE();

--------------------------------------------------------
-- Journalisation : début
--------------------------------------------------------

-- La journalisation ne doit jamais empêcher la sauvegarde :
-- en cas d'échec, on continue sans log (@LogId reste NULL).
BEGIN TRY

    INSERT INTO Log_Database.dbo.BackupExecutionLog
    (
        DatabaseName,
        BackupType,
        BackupFile,
        StartTime,
        Status
    )
    VALUES
    (
        @DBName,
        'DIFFERENTIAL',
        @FileName,
        @StartTime,
        'RUNNING'
    );

    SET @LogId = SCOPE_IDENTITY();

END TRY
BEGIN CATCH

    PRINT 'Avertissement : journalisation indisponible - ' + ERROR_MESSAGE();

END CATCH;

--------------------------------------------------------
-- Début du traitement
--------------------------------------------------------

BEGIN TRY

    PRINT 'Début de la sauvegarde : ' + CONVERT(VARCHAR,@StartTime,120);

    ----------------------------------------------------
    -- Contrôles préalables
    ----------------------------------------------------

    IF DB_ID(@DBName) IS NULL
    BEGIN
        SET @ErrorMessage = 'La base ' + @DBName + ' n''existe pas.';
        THROW 50001, @ErrorMessage, 1;
    END;

    -- Une différentielle exige une sauvegarde FULL de base
    -- (differential_base_lsn est NULL tant qu'aucune FULL n'a été faite)
    IF EXISTS (SELECT 1 FROM sys.master_files
               WHERE database_id = DB_ID(@DBName)
                 AND file_id = 1
                 AND differential_base_lsn IS NULL)
    BEGIN
        SET @ErrorMessage = 'Aucune sauvegarde FULL de base pour ' + @DBName + ' : sauvegarde différentielle impossible.';
        THROW 50002, @ErrorMessage, 1;
    END;

    -- Création du dossier de destination s'il n'existe pas
    EXEC master.dbo.xp_create_subdir @BackupPath;

    BACKUP DATABASE @DBName
    TO DISK=@FileName
    WITH
        DIFFERENTIAL,
        INIT,
        COMPRESSION,
        CHECKSUM,
        STATS=10;

    ----------------------------------------------------
    -- Vérification de la sauvegarde
    ----------------------------------------------------

    RESTORE VERIFYONLY
    FROM DISK=@FileName
    WITH CHECKSUM;

    ----------------------------------------------------
    -- Fin
    ----------------------------------------------------

    SET @EndTime = GETDATE();

    SET @Duration = DATEDIFF(SECOND,@StartTime,@EndTime);

    IF @LogId IS NOT NULL
    BEGIN
        BEGIN TRY

            UPDATE Log_Database.dbo.BackupExecutionLog
            SET

                EndTime=@EndTime,
                DurationSeconds=@Duration,
                Status='SUCCESS'

            WHERE Id=@LogId;

        END TRY
        BEGIN CATCH

            PRINT 'Avertissement : mise à jour du log impossible - ' + ERROR_MESSAGE();
        END CATCH;
    END;

    PRINT 'Sauvegarde terminée avec succès.';
    PRINT 'Durée : ' + CAST(@Duration AS VARCHAR) + ' secondes';

END TRY

BEGIN CATCH

    SET @EndTime = GETDATE();

    SET @Duration = DATEDIFF(SECOND,@StartTime,@EndTime);

    SET @ErrorMessage = 'Erreur ' + CAST(ERROR_NUMBER() AS NVARCHAR(10)) + ' : ' + ERROR_MESSAGE();

    IF @LogId IS NOT NULL
    BEGIN
        BEGIN TRY

            UPDATE Log_Database.dbo.BackupExecutionLog
            SET

                EndTime=@EndTime,
                DurationSeconds=@Duration,
                Status='FAILED',
                ErrorMessage=@ErrorMessage

            WHERE Id=@LogId;

        END TRY
        BEGIN CATCH

            PRINT 'Avertissement : mise à jour du log impossible - ' + ERROR_MESSAGE();
        END CATCH;
    END;

    PRINT 'Erreur : ' + @ErrorMessage;

    THROW;

END CATCH;