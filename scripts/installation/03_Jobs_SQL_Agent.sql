/********************************************************************
 Description  : Création des jobs SQL Agent de sauvegarde de
                BD_ATLANTIS_SGI et des alertes par e-mail en cas
                d'échec. Script ré-exécutable : les jobs existants
                sont supprimés puis recréés.
 Ordre        : 3/3 (après 02_usp_BackupDatabase.sql)

 Planning :
    FULL : dimanche 01h00                       (rétention 552 h / 23 j)
    DIFF : lundi à samedi 01h00                 (rétention 360 h / 15 j)
    LOG  : toutes les 15 minutes, 24h/24        (rétention 168 h / 7 j)

 Prérequis :
    - un profil Database Mail opérationnel (voir @MailProfile) ;
    - le compte de service SQL Server doit pouvoir écrire dans @BackupRoot ;
    - après installation, lancer une première fois le job FULL :
      les jobs DIFF et LOG échouent tant qu'aucune FULL n'existe.
********************************************************************/

USE [msdb];
GO

--------------------------------------------------------
-- PARAMÈTRES
--------------------------------------------------------

DECLARE @DBName SYSNAME = N'BD_ATLANTIS_SGI';
DECLARE @BackupRoot NVARCHAR(256) = N'C:\Backups\AtlantisBackup\';
DECLARE @JobLogPath NVARCHAR(256) = N'C:\Backups\AtlantisBackup\JobLogs\';

DECLARE @OperatorName SYSNAME = N'DBA_ATLANTIS';
DECLARE @OperatorEmail NVARCHAR(100) = N'dba@votre-domaine.com';    -- À MODIFIER
DECLARE @MailProfile SYSNAME = N'DBA_Mail';                          -- À MODIFIER : profil Database Mail existant

--------------------------------------------------------
-- VARIABLES DE TRAVAIL
--------------------------------------------------------

DECLARE @Jobs TABLE
(
    Id                 INT IDENTITY(1,1) PRIMARY KEY,
    BackupType         VARCHAR(4),
    RetentionHours     INT,
    FreqType           INT,     -- 4 = quotidien, 8 = hebdomadaire
    FreqInterval       INT,     -- hebdo : 1 = dimanche, 126 = lundi..samedi
    FreqSubdayType     INT,     -- 1 = à l'heure indiquée, 4 = toutes les N minutes
    FreqSubdayInterval INT,
    StartTime          INT,     -- HHMMSS
    Description        NVARCHAR(200)
);

INSERT INTO @Jobs VALUES
    ('FULL', 552, 8, 1,   1, 0,  10000, N'Sauvegarde FULL hebdomadaire (dimanche 01h00)'),
    ('DIFF', 360, 8, 126, 1, 0,  10000, N'Sauvegarde DIFF quotidienne (lundi à samedi 01h00)'),
    ('LOG',  168, 4, 1,   4, 15, 0,     N'Sauvegarde LOG toutes les 15 minutes');

DECLARE @i INT = 1;
DECLARE @JobId UNIQUEIDENTIFIER;
DECLARE @JobName SYSNAME;
DECLARE @StepName SYSNAME;
DECLARE @ScheduleName SYSNAME;
DECLARE @Command NVARCHAR(MAX);
DECLARE @OutputFile NVARCHAR(500);
DECLARE @Owner SYSNAME = SUSER_SNAME(0x01);   -- compte sa, même renommé

DECLARE @BackupType VARCHAR(4);
DECLARE @RetentionHours INT;
DECLARE @FreqType INT;
DECLARE @FreqInterval INT;
DECLARE @FreqSubdayType INT;
DECLARE @FreqSubdayInterval INT;
DECLARE @StartTime INT;
DECLARE @Description NVARCHAR(200);

--------------------------------------------------------
-- 1. Profil Database Mail utilisé par SQL Agent
--------------------------------------------------------

IF EXISTS (SELECT 1 FROM msdb.dbo.sysmail_profile WHERE name = @MailProfile)
BEGIN
    EXEC msdb.dbo.sp_set_sqlagent_properties
        @use_databasemail = 1,
        @databasemail_profile = @MailProfile;
    PRINT '✓ Profil Database Mail associé à SQL Agent (redémarrer le service SQL Agent pour l''activer)';
END
ELSE
    PRINT '⚠ Profil Database Mail "' + @MailProfile + '" introuvable : les jobs seront créés mais aucun e-mail ne partira';

--------------------------------------------------------
-- 2. Dossier des journaux d'exécution des jobs
--    (sortie complète des étapes : tous les messages d'erreur,
--    y compris ceux que le CATCH T-SQL ne peut pas lire)
--------------------------------------------------------

EXEC master.dbo.xp_create_subdir @JobLogPath;

BEGIN TRY
    BEGIN TRANSACTION;

    --------------------------------------------------------
    -- 3. Opérateur destinataire des alertes
    --------------------------------------------------------

    IF NOT EXISTS (SELECT 1 FROM msdb.dbo.sysoperators WHERE name = @OperatorName)
        EXEC msdb.dbo.sp_add_operator @name = @OperatorName, @enabled = 1, @email_address = @OperatorEmail;
    ELSE
        EXEC msdb.dbo.sp_update_operator @name = @OperatorName, @enabled = 1, @email_address = @OperatorEmail;

    PRINT '✓ Opérateur ' + @OperatorName + ' (' + @OperatorEmail + ')';

    --------------------------------------------------------
    -- 4. Jobs de sauvegarde
    --------------------------------------------------------

    WHILE @i <= (SELECT COUNT(*) FROM @Jobs)
    BEGIN
        SELECT
            @BackupType         = BackupType,
            @RetentionHours     = RetentionHours,
            @FreqType           = FreqType,
            @FreqInterval       = FreqInterval,
            @FreqSubdayType     = FreqSubdayType,
            @FreqSubdayInterval = FreqSubdayInterval,
            @StartTime          = StartTime,
            @Description        = Description
        FROM @Jobs
        WHERE Id = @i;

        SET @JobName      = N'ATLANTIS - Sauvegarde ' + @BackupType + N' - ' + @DBName;
        SET @StepName     = N'Sauvegarde ' + @BackupType;
        SET @ScheduleName = @JobName;
        SET @OutputFile   = @JobLogPath + @DBName + N'_' + @BackupType + N'.txt';
        SET @Command      = N'EXEC dbo.usp_BackupDatabase'
                          + N' @DBName = N''' + REPLACE(@DBName, '''', '''''') + N''','
                          + N' @BackupType = ''' + @BackupType + N''','
                          + N' @BackupRoot = N''' + REPLACE(@BackupRoot, '''', '''''') + N''','
                          + N' @RetentionHours = ' + CAST(@RetentionHours AS NVARCHAR(10)) + N';';

        IF EXISTS (SELECT 1 FROM msdb.dbo.sysjobs WHERE name = @JobName)
            EXEC msdb.dbo.sp_delete_job @job_name = @JobName, @delete_unused_schedule = 1;

        SET @JobId = NULL;

        EXEC msdb.dbo.sp_add_job
            @job_name                   = @JobName,
            @enabled                    = 1,
            @description                = @Description,
            @owner_login_name           = @Owner,
            @notify_level_eventlog      = 2,        -- en cas d'échec
            @notify_level_email         = 2,        -- en cas d'échec
            @notify_email_operator_name = @OperatorName,
            @job_id                     = @JobId OUTPUT;

        EXEC msdb.dbo.sp_add_jobstep
            @job_id            = @JobId,
            @step_name         = @StepName,
            @subsystem         = N'TSQL',
            @database_name     = N'Log_Database',
            @command           = @Command,
            @output_file_name  = @OutputFile,
            @on_success_action = 1,                 -- quitter en signalant le succès
            @on_fail_action    = 2;                 -- quitter en signalant l'échec

        EXEC msdb.dbo.sp_add_jobschedule
            @job_id                 = @JobId,
            @name                   = @ScheduleName,
            @enabled                = 1,
            @freq_type              = @FreqType,
            @freq_interval          = @FreqInterval,
            @freq_subday_type       = @FreqSubdayType,
            @freq_subday_interval   = @FreqSubdayInterval,
            @freq_recurrence_factor = 1,
            @active_start_time      = @StartTime;

        EXEC msdb.dbo.sp_add_jobserver @job_id = @JobId, @server_name = N'(local)';

        PRINT '✓ Job créé : ' + @JobName + ' - ' + @Description;

        SET @i += 1;
    END

    COMMIT TRANSACTION;

    PRINT '';
    PRINT 'Installation terminée. Lancer une première fois le job FULL :';
    PRINT '    EXEC msdb.dbo.sp_start_job @job_name = N''ATLANTIS - Sauvegarde FULL - ' + @DBName + ''';';

END TRY
BEGIN CATCH
    IF @@TRANCOUNT > 0
        ROLLBACK TRANSACTION;
    THROW;
END CATCH;
GO
