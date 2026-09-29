-- Declaration des variables

DECLARE @BackupPath NVARCHAR(256) = 'C:\Backups\AtlantisBackup\FULL\';
DECLARE @DBName NVARCHAR(128) = 'BD_ATLANTIS_SGI';
DECLARE @FileName NVARCHAR(500);
DECLARE @FileDate NVARCHAR(30);
DECLARE @Day NVARCHAR(2);
DECLARE @Month NVARCHAR(2);
DECLARE @Year NVARCHAR(4);
DECLARE @Hour NVARCHAR(2);
DECLARE @Minute NVARCHAR(2);
DECLARE @Second NVARCHAR(2);
DECLARE @BackupType NVARCHAR(20) = 'FULL';

DECLARE @StartTime DATETIME;
DECLARE @EndTime DATETIME;
DECLARE @Duration INT;
DECLARE @ErrorMessage NVARCHAR(MAX);
DECLARE @LogId INT;

-- Extraire les composants de la date et de l'heure
SET @Day = CONVERT(NVARCHAR(2), DAY(GETDATE()));
SET @Month = CONVERT(NVARCHAR(2), MONTH(GETDATE()));
SET @Year = CONVERT(NVARCHAR(4), YEAR(GETDATE()));
SET @Hour = CONVERT(NVARCHAR(2), DATEPART(HOUR, GETDATE()));
SET @Minute = CONVERT(NVARCHAR(2), DATEPART(MINUTE, GETDATE()));
SET @Second = CONVERT(NVARCHAR(2), DATEPART(SECOND, GETDATE()));

-- Ajouter des zéros devant si nécessaire
IF LEN(@Day) = 1 SET @Day = '0' + @Day;
IF LEN(@Month) = 1 SET @Month = '0' + @Month;
IF LEN(@Year) = 1 SET @Year = '0' + @Year;
IF LEN(@Hour) = 1 SET @Hour = '0' + @Hour;
IF LEN(@Minute) = 1 SET @Minute = '0' + @Minute;
IF LEN(@Second) = 1 SET @Second = '0' + @Second;

-- Construction du nom du fichier
SET @FileDate = @Day + '-' + @Month + '-' + @Year + '_' + @Hour + 'H' + @Minute + 'M' + @Second + 'S';
SET @FileName = @BackupPath + @DBName + '_' + @FileDate + '_FULL.bak';

SET @StartTime = GETDATE();

-- Journalisation : début
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
        @BackupType,
        @FileName,
        @StartTime,
        'RUNNING'
    );

    SET @LogId = SCOPE_IDENTITY();
END TRY
BEGIN CATCH
    PRINT 'Avertissement : journalisation indisponible - ' + ERROR_MESSAGE();
END CATCH;

BEGIN TRY

    PRINT 'Début de la sauvegarde : ' + CONVERT(VARCHAR, @StartTime, 120);


    BACKUP DATABASE @DBName
    TO DISK = @FileName
    WITH
        INIT,
        COMPRESSION,
        CHECKSUM,
        STATS = 10;

    -- Vérification de la sauvegarde
    RESTORE VERIFYONLY
    FROM DISK = @FileName;

    SET @EndTime = GETDATE();
    SET @Duration = DATEDIFF(SECOND, @StartTime, @EndTime);

    IF @LogId IS NOT NULL
    BEGIN
        BEGIN TRY
            UPDATE Log_Database.dbo.BackupExecutionLog
            SET
                EndTime = @EndTime,
                DurationSeconds = @Duration,
                Status = 'SUCCESS'
            WHERE Id = @LogId;
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
    SET @Duration = DATEDIFF(SECOND, @StartTime, @EndTime);
    SET @ErrorMessage = ERROR_MESSAGE();

    IF @LogId IS NOT NULL
    BEGIN
        BEGIN TRY
            UPDATE Log_Database.dbo.BackupExecutionLog
            SET
                EndTime = @EndTime,
                DurationSeconds = @Duration,
                Status = 'FAILED',
                ErrorMessage = @ErrorMessage
            WHERE Id = @LogId;
        END TRY
        BEGIN CATCH
            PRINT 'Avertissement : mise à jour du log impossible - ' + ERROR_MESSAGE();
        END CATCH;
    END;

    PRINT 'Erreur : ' + @ErrorMessage;

    THROW;

END CATCH;
GO