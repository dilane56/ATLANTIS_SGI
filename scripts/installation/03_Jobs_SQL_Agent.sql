/********************************************************************
 Description  : Création des jobs SQL Agent de sauvegarde des bases
                Atlantis SGI, Sage compta et Sage paie, et des alertes
                par e-mail en cas d'échec. Script ré-exécutable : les
                jobs existants sont supprimés puis recréés.
 Ordre        : 3/3 (après 02_usp_BackupDatabase.sql)

 Planning (Politique de Retention.txt) :
    Atlantis SGI  FULL samedi 22h00 | DIFF lun-sam 20h00 | LOG toutes les heures lun-sam 08h-19h
    Sage compta   FULL samedi 21h00 | DIFF lun-sam 19h30 | LOG toutes les heures lun-sam 08h-19h
    Sage paie     FULL le 20 et le 27 à 20h00 | DIFF lun-sam 19h00 | pas de LOG

 Prérequis :
    - renseigner le nom des bases Sage dans @Bases (une base introuvable
      est ignorée avec un avertissement, ses jobs ne sont pas créés) ;
    - un profil Database Mail opérationnel (voir @MailProfile) ;
    - le compte de service SQL Server doit pouvoir écrire dans chaque BackupRoot ;
    - après installation, lancer une première fois le job FULL de chaque base :
      les jobs DIFF et LOG échouent tant qu'aucune FULL n'existe.
********************************************************************/

USE [msdb];
GO

--------------------------------------------------------
-- PARAMÈTRES
--------------------------------------------------------

DECLARE @OperatorName SYSNAME = N'DBA_ATLANTIS';
DECLARE @OperatorEmail NVARCHAR(100) = N'dba@votre-domaine.com';    -- À MODIFIER
DECLARE @MailProfile SYSNAME = N'DBA_Mail';                          -- À MODIFIER : profil Database Mail existant

-- Bases sauvegardées. Les journaux d'exécution des jobs vont dans BackupRoot\JobLogs\.
DECLARE @Bases TABLE
(
    Code       VARCHAR(20) PRIMARY KEY,
    JobPrefix  NVARCHAR(50),
    DBName     SYSNAME,
    BackupRoot NVARCHAR(256)
);

INSERT INTO @Bases (Code, JobPrefix, DBName, BackupRoot) VALUES
    ('ATLANTIS',    N'ATLANTIS',    N'BD_ATLANTIS_SGI',        N'C:\Backups\AtlantisBackup\'),
    ('SAGE_COMPTA', N'SAGE COMPTA', N'<NOM_BASE_SAGE_COMPTA>', N'C:\Backups\SageComptaBackup\'),   -- À MODIFIER
    ('SAGE_PAIE',   N'SAGE PAIE',   N'<NOM_BASE_SAGE_PAIE>',   N'C:\Backups\SagePaieBackup\');    -- À MODIFIER

-- Plannings : une ligne par planification. Plusieurs lignes pour la même
-- base et le même type = un seul job avec plusieurs planifications.
--   FreqType       4 = quotidien, 8 = hebdomadaire, 16 = mensuel
--   FreqInterval   hebdo : 64 = samedi, 126 = lundi..samedi ; mensuel : jour du mois
--   FreqSubdayType 1 = une fois à StartTime, 8 = toutes les N heures entre StartTime et EndTime
--   StartTime / EndTime au format HHMMSS
DECLARE @Plannings TABLE
(
    Id                 INT IDENTITY(1,1) PRIMARY KEY,
    Base               VARCHAR(20),
    BackupType         VARCHAR(4),
    RetentionHours     INT,
    FreqType           INT,
    FreqInterval       INT,
    FreqSubdayType     INT,
    FreqSubdayInterval INT,
    StartTime          INT,
    EndTime            INT,
    Libelle            NVARCHAR(100)
);

INSERT INTO @Plannings (Base, BackupType, RetentionHours, FreqType, FreqInterval, FreqSubdayType, FreqSubdayInterval, StartTime, EndTime, Libelle) VALUES
    -- Atlantis SGI
    ('ATLANTIS',    'FULL', 552,  8,  64, 1, 0, 220000, 235959, N'samedi 22h00'),
    ('ATLANTIS',    'DIFF', 360,  8, 126, 1, 0, 200000, 235959, N'lundi à samedi 20h00'),
    ('ATLANTIS',    'LOG',  168,  8, 126, 8, 1,  80000, 190000, N'toutes les heures, lundi à samedi 08h00-19h00'),
    -- Sage compta
    ('SAGE_COMPTA', 'FULL', 552,  8,  64, 1, 0, 210000, 235959, N'samedi 21h00'),
    ('SAGE_COMPTA', 'DIFF', 360,  8, 126, 1, 0, 193000, 235959, N'lundi à samedi 19h30'),
    ('SAGE_COMPTA', 'LOG',  168,  8, 126, 8, 1,  80000, 190000, N'toutes les heures, lundi à samedi 08h00-19h00'),
    -- Sage paie
    ('SAGE_PAIE',   'FULL', 768, 16,  20, 1, 0, 200000, 235959, N'le 20 du mois à 20h00'),
    ('SAGE_PAIE',   'FULL', 768, 16,  27, 1, 0, 200000, 235959, N'le 27 du mois à 20h00'),
    ('SAGE_PAIE',   'DIFF', 600,  8, 126, 1, 0, 190000, 235959, N'lundi à samedi 19h00');

--------------------------------------------------------
-- VARIABLES DE TRAVAIL
--------------------------------------------------------

DECLARE @JobList TABLE (Id INT IDENTITY(1,1) PRIMARY KEY, Base VARCHAR(20), BackupType VARCHAR(4));

DECLARE @i INT = 1;
DECLARE @s INT;
DECLARE @JobId UNIQUEIDENTIFIER;
DECLARE @JobName SYSNAME;
DECLARE @StepName SYSNAME;
DECLARE @ScheduleName SYSNAME;
DECLARE @Command NVARCHAR(MAX);
DECLARE @OutputFile NVARCHAR(500);
DECLARE @JobLogPath NVARCHAR(256);
DECLARE @Owner SYSNAME = SUSER_SNAME(0x01);   -- compte sa, même renommé
DECLARE @Avertissements NVARCHAR(MAX);
DECLARE @JobsFull NVARCHAR(MAX) = N'';

DECLARE @Base VARCHAR(20);
DECLARE @JobPrefix NVARCHAR(50);
DECLARE @DBName SYSNAME;
DECLARE @BackupRoot NVARCHAR(256);
DECLARE @BackupType VARCHAR(4);
DECLARE @RetentionHours INT;
DECLARE @Description NVARCHAR(512);
DECLARE @FreqType INT;
DECLARE @FreqInterval INT;
DECLARE @FreqSubdayType INT;
DECLARE @FreqSubdayInterval INT;
DECLARE @StartTime INT;
DECLARE @EndTime INT;
DECLARE @Libelle NVARCHAR(100);

INSERT INTO @JobList (Base, BackupType)
SELECT Base, BackupType
FROM @Plannings
GROUP BY Base, BackupType
ORDER BY MIN(Id);

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

BEGIN TRY
    BEGIN TRANSACTION;

    --------------------------------------------------------
    -- 2. Opérateur destinataire des alertes
    --------------------------------------------------------

    IF NOT EXISTS (SELECT 1 FROM msdb.dbo.sysoperators WHERE name = @OperatorName)
        EXEC msdb.dbo.sp_add_operator @name = @OperatorName, @enabled = 1, @email_address = @OperatorEmail;
    ELSE
        EXEC msdb.dbo.sp_update_operator @name = @OperatorName, @enabled = 1, @email_address = @OperatorEmail;

    PRINT '✓ Opérateur ' + @OperatorName + ' (' + @OperatorEmail + ')';
    PRINT '';

    --------------------------------------------------------
    -- 3. Jobs de sauvegarde (un job par base et par type)
    --------------------------------------------------------

    WHILE @i <= (SELECT COUNT(*) FROM @JobList)
    BEGIN
        SELECT @Base = Base, @BackupType = BackupType FROM @JobList WHERE Id = @i;
        SELECT @JobPrefix = JobPrefix, @DBName = DBName, @BackupRoot = BackupRoot FROM @Bases WHERE Code = @Base;

        SET @JobName = @JobPrefix + N' - Sauvegarde ' + @BackupType + N' - ' + @DBName;

        -- Base introuvable (nom non renseigné ou erroné) : jobs ignorés
        IF DB_ID(@DBName) IS NULL
        BEGIN
            PRINT '⚠ Base "' + @DBName + '" introuvable : job ' + @JobPrefix + ' ' + @BackupType + ' non créé';
            SET @i += 1;
            CONTINUE;
        END

        SELECT
            @RetentionHours = MAX(RetentionHours),
            @Description    = N'Sauvegarde ' + @BackupType + N' : ' + STRING_AGG(Libelle, N' + ') WITHIN GROUP (ORDER BY Id)
        FROM @Plannings
        WHERE Base = @Base AND BackupType = @BackupType;

        SET @StepName   = N'Sauvegarde ' + @BackupType;
        SET @JobLogPath = @BackupRoot + N'JobLogs\';
        SET @OutputFile = @JobLogPath + @DBName + N'_' + @BackupType + N'.txt';
        SET @Command    = N'EXEC dbo.usp_BackupDatabase'
                        + N' @DBName = N''' + REPLACE(@DBName, '''', '''''') + N''','
                        + N' @BackupType = ''' + @BackupType + N''','
                        + N' @BackupRoot = N''' + REPLACE(@BackupRoot, '''', '''''') + N''','
                        + N' @RetentionHours = ' + CAST(@RetentionHours AS NVARCHAR(10)) + N';';

        -- Dossier des journaux d'exécution (sortie complète des étapes :
        -- tous les messages d'erreur, y compris ceux que le CATCH T-SQL ne peut pas lire)
        EXEC master.dbo.xp_create_subdir @JobLogPath;

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

        -- Planifications du job
        SELECT @s = MIN(Id) FROM @Plannings WHERE Base = @Base AND BackupType = @BackupType;
        WHILE @s IS NOT NULL
        BEGIN
            SELECT
                @FreqType           = FreqType,
                @FreqInterval       = FreqInterval,
                @FreqSubdayType     = FreqSubdayType,
                @FreqSubdayInterval = FreqSubdayInterval,
                @StartTime          = StartTime,
                @EndTime            = EndTime,
                @Libelle            = Libelle
            FROM @Plannings
            WHERE Id = @s;

            SET @ScheduleName = @JobName + N' - ' + @Libelle;

            EXEC msdb.dbo.sp_add_jobschedule
                @job_id                 = @JobId,
                @name                   = @ScheduleName,
                @enabled                = 1,
                @freq_type              = @FreqType,
                @freq_interval          = @FreqInterval,
                @freq_subday_type       = @FreqSubdayType,
                @freq_subday_interval   = @FreqSubdayInterval,
                @freq_recurrence_factor = 1,
                @active_start_time      = @StartTime,
                @active_end_time        = @EndTime;

            SELECT @s = MIN(Id) FROM @Plannings WHERE Base = @Base AND BackupType = @BackupType AND Id > @s;
        END

        EXEC msdb.dbo.sp_add_jobserver @job_id = @JobId, @server_name = N'(local)';

        PRINT '✓ Job créé : ' + @JobName;
        PRINT '    ' + @Description + ' (rétention ' + CAST(@RetentionHours AS VARCHAR(10)) + ' h)';

        IF @BackupType = 'FULL'
            SET @JobsFull += N'    EXEC msdb.dbo.sp_start_job @job_name = N''' + REPLACE(@JobName, '''', '''''') + N''';' + CHAR(13) + CHAR(10);

        SET @i += 1;
    END

    COMMIT TRANSACTION;

    --------------------------------------------------------
    -- 4. Cohérence mode de récupération / sauvegarde LOG
    --------------------------------------------------------

    -- Mode FULL sans job LOG : le journal de transactions grossit indéfiniment
    SELECT @Avertissements = STRING_AGG(CAST(N'⚠ ' + b.DBName + N' est en mode ' + d.recovery_model_desc
               + N' sans sauvegarde LOG : son journal va grossir indéfiniment (passer la base en SIMPLE ou ajouter un job LOG)' AS NVARCHAR(MAX)), CHAR(13) + CHAR(10))
    FROM @Bases AS b
    JOIN sys.databases AS d ON d.name = b.DBName
    WHERE d.recovery_model_desc <> 'SIMPLE'
      AND NOT EXISTS (SELECT 1 FROM @Plannings AS p WHERE p.Base = b.Code AND p.BackupType = 'LOG');

    IF @Avertissements IS NOT NULL
    BEGIN
        PRINT '';
        PRINT @Avertissements;
    END

    -- Job LOG sur une base en mode SIMPLE : le job échouera à chaque exécution
    SET @Avertissements = NULL;
    SELECT @Avertissements = STRING_AGG(CAST(N'⚠ ' + b.DBName
               + N' est en mode SIMPLE alors qu''un job LOG est prévu : ce job échouera (passer la base en FULL)' AS NVARCHAR(MAX)), CHAR(13) + CHAR(10))
    FROM @Bases AS b
    JOIN sys.databases AS d ON d.name = b.DBName
    WHERE d.recovery_model_desc = 'SIMPLE'
      AND EXISTS (SELECT 1 FROM @Plannings AS p WHERE p.Base = b.Code AND p.BackupType = 'LOG');

    IF @Avertissements IS NOT NULL
    BEGIN
        PRINT '';
        PRINT @Avertissements;
    END

    IF @JobsFull <> N''
    BEGIN
        PRINT '';
        PRINT 'Installation terminée. Lancer une première fois les jobs FULL :';
        PRINT @JobsFull;
    END

END TRY
BEGIN CATCH
    IF @@TRANCOUNT > 0
        ROLLBACK TRANSACTION;
    THROW;
END CATCH;
GO
