-- =====================================================
-- RESTAURATION FULL + DIFF + LOG (avec point dans le temps)
-- SQL Server 2017 ou supérieur (STRING_AGG)
-- =====================================================

USE [master];
GO

-- =====================================================
-- PARAMÈTRES
-- =====================================================

DECLARE @DatabaseName NVARCHAR(128) = 'BD_ATLANTIS_SGI';
DECLARE @BackupFilePathFULL NVARCHAR(500) = 'C:\Backups\AtlantisBackup\FULL\BD_ATLANTIS_SGI_20260927_010000_FULL.bak';
-- NULL si aucune différentielle n'est à appliquer
DECLARE @BackupFilePathDIFF NVARCHAR(500) = 'C:\Backups\AtlantisBackup\DIFF\BD_ATLANTIS_SGI_20260929_010000_DIFF.bak';

-- Journaux à appliquer, DANS L'ORDRE chronologique (voir la liste plus bas).
-- Avec @StopAt, lister les journaux jusqu'à celui qui contient @StopAt inclus.
DECLARE @LogFiles TABLE (Ordre INT IDENTITY(1,1) PRIMARY KEY, FilePath NVARCHAR(500));
INSERT INTO @LogFiles (FilePath) VALUES
    ('C:\Backups\AtlantisBackup\LOG\BD_ATLANTIS_SGI_20260929_011500_LOG.trn'),
    ('C:\Backups\AtlantisBackup\LOG\BD_ATLANTIS_SGI_20260929_013000_LOG.trn');

-- Point dans le temps de la restauration. NULL = appliquer les journaux en entier.
DECLARE @StopAt DATETIME = NULL;          -- ex. '2026-09-29 14:30:00'

-- Sauvegarde de fin de journal (tail-log) avant d'écraser une base existante :
-- conserve les transactions postérieures à la dernière sauvegarde LOG.
DECLARE @TailLogBackup BIT = 1;
DECLARE @TailLogPath NVARCHAR(256) = 'C:\Backups\AtlantisBackup\TAILLOG\';

-- Emplacement des fichiers restaurés (WITH MOVE). NULL = chemins d'origine de la sauvegarde.
-- À renseigner pour restaurer sous un autre nom ou sur un autre serveur,
-- sinon REPLACE peut viser les fichiers d'une autre base.
DECLARE @DataPath NVARCHAR(256) = NULL;   -- ex. 'D:\SQLData\'
DECLARE @LogPath NVARCHAR(256) = NULL;    -- ex. 'E:\SQLLogs\'

-- Contrôle d'intégrité après restauration
DECLARE @RunCheckDB BIT = 1;

-- =====================================================
-- VARIABLES DE TRAVAIL
-- =====================================================

DECLARE @StartTime DATETIME = GETDATE();
DECLARE @SQL NVARCHAR(MAX);
DECLARE @MoveClause NVARCHAR(MAX) = N'';
DECLARE @TailLogFile NVARCHAR(500);
DECLARE @LogFile NVARCHAR(500);
DECLARE @i INT;
DECLARE @NbLogs INT;
DECLARE @Etape NVARCHAR(200);
DECLARE @EtatInitial NVARCHAR(60);
DECLARE @EtatActuel NVARCHAR(60);
DECLARE @RestoreStarted BIT = 0;
DECLARE @RestoreLogId INT;
DECLARE @ErrorNumber INT;
DECLARE @ErrorMessage NVARCHAR(4000);

DECLARE @FileList TABLE
(
    LogicalName NVARCHAR(128), PhysicalName NVARCHAR(260), Type CHAR(1),
    FileGroupName NVARCHAR(128), Size NUMERIC(20,0), MaxSize NUMERIC(20,0),
    FileId BIGINT, CreateLSN NUMERIC(25,0), DropLSN NUMERIC(25,0),
    UniqueId UNIQUEIDENTIFIER, ReadOnlyLSN NUMERIC(25,0), ReadWriteLSN NUMERIC(25,0),
    BackupSizeInBytes BIGINT, SourceBlockSize INT, FileGroupId INT,
    LogGroupGUID UNIQUEIDENTIFIER, DifferentialBaseLSN NUMERIC(25,0),
    DifferentialBaseGUID UNIQUEIDENTIFIER, IsReadOnly BIT, IsPresent BIT,
    TDEThumbprint VARBINARY(32), SnapshotUrl NVARCHAR(360)
);

DECLARE @Orphelins TABLE (UserName SYSNAME);

SELECT @NbLogs = COUNT(*) FROM @LogFiles;

PRINT '═══════════════════════════════════════════════════════════';
PRINT 'RESTAURATION FULL + DIFF + LOG';
PRINT '═══════════════════════════════════════════════════════════';
PRINT 'Base de données: ' + @DatabaseName;
PRINT 'Sauvegarde FULL: ' + @BackupFilePathFULL;
PRINT 'Sauvegarde DIFF: ' + ISNULL(@BackupFilePathDIFF, '(aucune)');
PRINT 'Journaux (LOG): ' + CAST(@NbLogs AS NVARCHAR(10)) + ' fichier(s)';
PRINT 'Point dans le temps: ' + ISNULL(CONVERT(NVARCHAR(20), @StopAt, 120), '(fin des journaux)');
PRINT '───────────────────────────────────────────────────────────';
PRINT '';

-- Journalisation : début (ne doit jamais empêcher la restauration)
-- Via sp_executesql : si Log_Database est absente (ex. serveur de secours),
-- l'erreur reste interceptable par le CATCH au lieu d'interrompre le script.
DECLARE @LogRestoreType NVARCHAR(20) = CASE WHEN @BackupFilePathDIFF IS NULL THEN 'FULL+LOG' ELSE 'FULL+DIFF+LOG' END;
DECLARE @LogBackupFiles NVARCHAR(MAX);

SELECT @LogBackupFiles = @BackupFilePathFULL
    + ISNULL(' | ' + @BackupFilePathDIFF, '')
    + ISNULL(' | ' + STRING_AGG(CAST(FilePath AS NVARCHAR(MAX)), ' | ') WITHIN GROUP (ORDER BY Ordre), '')
FROM @LogFiles;

BEGIN TRY
    EXEC sp_executesql
        N'INSERT INTO Log_Database.dbo.RestoreExecutionLog (DatabaseName, RestoreType, BackupFiles, StopAt, StartTime, Status)
          VALUES (@DatabaseName, @RestoreType, @BackupFiles, @StopAt, @StartTime, ''RUNNING'');
          SET @RestoreLogId = SCOPE_IDENTITY();',
        N'@DatabaseName NVARCHAR(128), @RestoreType NVARCHAR(20), @BackupFiles NVARCHAR(MAX), @StopAt DATETIME, @StartTime DATETIME, @RestoreLogId INT OUTPUT',
        @DatabaseName = @DatabaseName, @RestoreType = @LogRestoreType, @BackupFiles = @LogBackupFiles,
        @StopAt = @StopAt, @StartTime = @StartTime, @RestoreLogId = @RestoreLogId OUTPUT;
END TRY
BEGIN CATCH
    PRINT 'Avertissement : journalisation indisponible - ' + ERROR_MESSAGE();
END CATCH;

BEGIN TRY

    -- =====================================================
    -- ÉTAPE 1: VÉRIFIER TOUS LES FICHIERS AVANT DE TOUCHER À LA BASE
    -- (la cohérence de la chaîne FULL → DIFF → LOG est ensuite
    -- contrôlée par SQL Server lui-même à chaque RESTORE)
    -- =====================================================

    SET @Etape = 'ÉTAPE 1 - Vérification des fichiers';
    PRINT '[ÉTAPE 1] Vérification des fichiers de sauvegarde...';

    RESTORE VERIFYONLY FROM DISK = @BackupFilePathFULL;
    PRINT '  ✓ Fichier FULL valide';

    IF @BackupFilePathDIFF IS NOT NULL
    BEGIN
        RESTORE VERIFYONLY FROM DISK = @BackupFilePathDIFF;
        PRINT '  ✓ Fichier DIFF valide';
    END

    SET @i = 1;
    WHILE @i <= @NbLogs
    BEGIN
        SELECT @LogFile = FilePath FROM @LogFiles WHERE Ordre = @i;
        SET @Etape = 'ÉTAPE 1 - Vérification de ' + @LogFile;
        RESTORE VERIFYONLY FROM DISK = @LogFile;
        PRINT '  ✓ Journal ' + CAST(@i AS NVARCHAR(10)) + ' valide';
        SET @i += 1;
    END
    PRINT '';

    -- =====================================================
    -- ÉTAPE 2: ISOLER LA BASE EXISTANTE
    -- Avec tail-log : SINGLE_USER puis BACKUP LOG WITH NORECOVERY
    -- (la base passe en RESTORING, plus aucune connexion possible).
    -- Sans tail-log : OFFLINE, qui ferme les connexions sans laisser
    -- une autre session prendre l'unique place du mode SINGLE_USER.
    -- =====================================================

    SET @Etape = 'ÉTAPE 2 - Isolation de la base existante';
    PRINT '[ÉTAPE 2] Isolation de la base existante...';

    SELECT @EtatInitial = state_desc FROM sys.databases WHERE name = @DatabaseName;

    IF @EtatInitial IS NULL
    BEGIN
        PRINT '  ℹ Base n''existe pas encore, une nouvelle base sera créée';
    END
    ELSE IF @EtatInitial <> 'ONLINE'
    BEGIN
        PRINT '  ℹ Base en état ' + @EtatInitial + ', pas d''isolation nécessaire';
    END
    ELSE IF @TailLogBackup = 1
        AND EXISTS (SELECT 1
                    FROM sys.databases AS d
                    JOIN sys.database_recovery_status AS rs ON rs.database_id = d.database_id
                    WHERE d.name = @DatabaseName
                      AND d.recovery_model_desc IN ('FULL','BULK_LOGGED')
                      AND rs.last_log_backup_lsn IS NOT NULL)
    BEGIN
        SET @TailLogFile = @TailLogPath + @DatabaseName + '_' + FORMAT(GETDATE(),'yyyyMMdd_HHmmss') + '_TAILLOG.trn';
        EXEC master.dbo.xp_create_subdir @TailLogPath;

        SET @SQL = N'ALTER DATABASE ' + QUOTENAME(@DatabaseName) + N' SET SINGLE_USER WITH ROLLBACK IMMEDIATE;';
        EXEC sp_executesql @SQL;

        BACKUP LOG @DatabaseName
        TO DISK = @TailLogFile
        WITH NORECOVERY, INIT, COMPRESSION, CHECKSUM, STATS = 10;

        PRINT '  ✓ Sauvegarde de fin de journal : ' + @TailLogFile;
    END
    ELSE
    BEGIN
        IF @TailLogBackup = 1
            PRINT '  ⚠ Tail-log impossible (mode SIMPLE ou aucune sauvegarde FULL) : les données depuis la dernière sauvegarde seront perdues';

        SET @SQL = N'ALTER DATABASE ' + QUOTENAME(@DatabaseName) + N' SET OFFLINE WITH ROLLBACK IMMEDIATE;';
        EXEC sp_executesql @SQL;
        PRINT '  ✓ Base mise hors ligne';
    END
    PRINT '';

    -- =====================================================
    -- ÉTAPE 3: PRÉPARER LE DÉPLACEMENT DES FICHIERS (WITH MOVE)
    -- =====================================================

    SET @Etape = 'ÉTAPE 3 - Préparation du WITH MOVE';

    IF @DataPath IS NOT NULL OR @LogPath IS NOT NULL
    BEGIN
        PRINT '[ÉTAPE 3] Préparation du déplacement des fichiers...';

        INSERT INTO @FileList
        EXEC sp_executesql N'RESTORE FILELISTONLY FROM DISK = @f;', N'@f NVARCHAR(500)', @f = @BackupFilePathFULL;

        SELECT @MoveClause = ISNULL(STRING_AGG(CAST(
                   N', MOVE N''' + REPLACE(LogicalName, '''', '''''') + N''' TO N'''
                 + REPLACE(CASE WHEN Type = 'L' THEN @LogPath ELSE @DataPath END
                         + @DatabaseName
                         + CASE WHEN FileId = 1  THEN N'.mdf'
                                WHEN Type = 'L'  THEN N'_' + LogicalName + N'.ldf'
                                WHEN Type = 'D'  THEN N'_' + LogicalName + N'.ndf'
                                ELSE N'_' + LogicalName END, '''', '''''')
                 + N'''' AS NVARCHAR(MAX)), N''), N'')
        FROM @FileList
        WHERE (Type = 'L' AND @LogPath IS NOT NULL)
           OR (Type <> 'L' AND @DataPath IS NOT NULL);

        PRINT '  ✓ Fichiers déplacés vers : ' + ISNULL(@DataPath, '(inchangé)') + ' / ' + ISNULL(@LogPath, '(inchangé)');
        PRINT '';
    END

    -- =====================================================
    -- ÉTAPE 4: RESTAURER LA SAUVEGARDE FULL (NORECOVERY)
    -- =====================================================

    SET @Etape = 'ÉTAPE 4 - Restauration FULL';
    PRINT '[ÉTAPE 4] Restauration de la sauvegarde FULL...';

    SET @RestoreStarted = 1;
    SET @SQL = N'RESTORE DATABASE ' + QUOTENAME(@DatabaseName)
             + N' FROM DISK = @f WITH REPLACE, NORECOVERY, STATS = 10' + @MoveClause + N';';
    EXEC sp_executesql @SQL, N'@f NVARCHAR(500)', @f = @BackupFilePathFULL;

    PRINT '  ✓ Sauvegarde FULL restaurée';
    PRINT '';

    -- =====================================================
    -- ÉTAPE 5: RESTAURER LA SAUVEGARDE DIFF (NORECOVERY)
    -- =====================================================

    IF @BackupFilePathDIFF IS NOT NULL
    BEGIN
        SET @Etape = 'ÉTAPE 5 - Restauration DIFF';
        PRINT '[ÉTAPE 5] Restauration de la sauvegarde DIFF...';

        RESTORE DATABASE @DatabaseName
        FROM DISK = @BackupFilePathDIFF
        WITH NORECOVERY, STATS = 10;

        PRINT '  ✓ Sauvegarde DIFF restaurée';
        PRINT '';
    END

    -- =====================================================
    -- ÉTAPE 6: RESTAURER LES JOURNAUX (NORECOVERY, STOPAT éventuel)
    -- =====================================================

    SET @i = 1;
    WHILE @i <= @NbLogs
    BEGIN
        SELECT @LogFile = FilePath FROM @LogFiles WHERE Ordre = @i;
        SET @Etape = 'ÉTAPE 6 - Restauration du journal ' + @LogFile;
        PRINT '[ÉTAPE 6] Journal ' + CAST(@i AS NVARCHAR(10)) + '/' + CAST(@NbLogs AS NVARCHAR(10)) + ' : ' + @LogFile;

        IF @StopAt IS NULL
            RESTORE LOG @DatabaseName
            FROM DISK = @LogFile
            WITH NORECOVERY, STATS = 10;
        ELSE
            RESTORE LOG @DatabaseName
            FROM DISK = @LogFile
            WITH NORECOVERY, STOPAT = @StopAt, STATS = 10;

        SET @i += 1;
    END
    IF @NbLogs > 0 PRINT '';

    -- =====================================================
    -- ÉTAPE 7: FINALISER (RECOVERY) ET REMETTRE EN MULTI_USER
    -- =====================================================

    SET @Etape = 'ÉTAPE 7 - Finalisation (RECOVERY)';
    PRINT '[ÉTAPE 7] Finalisation de la restauration...';

    RESTORE DATABASE @DatabaseName WITH RECOVERY;

    SET @SQL = N'ALTER DATABASE ' + QUOTENAME(@DatabaseName) + N' SET MULTI_USER;';
    EXEC sp_executesql @SQL;
    PRINT '  ✓ Base en ligne, mode multi-utilisateur';
    PRINT '';

    -- =====================================================
    -- ÉTAPE 8: CONTRÔLE D'INTÉGRITÉ
    -- =====================================================

    IF @RunCheckDB = 1
    BEGIN
        SET @Etape = 'ÉTAPE 8 - DBCC CHECKDB';
        PRINT '[ÉTAPE 8] Contrôle d''intégrité (DBCC CHECKDB)...';
        DBCC CHECKDB (@DatabaseName) WITH NO_INFOMSGS, ALL_ERRORMSGS;
        PRINT '  ✓ Aucune corruption détectée';
        PRINT '';
    END

    -- =====================================================
    -- ÉTAPE 9: UTILISATEURS ORPHELINS
    -- (utilisateurs SQL sans login correspondant sur ce serveur)
    -- =====================================================

    SET @Etape = 'ÉTAPE 9 - Utilisateurs orphelins';
    PRINT '[ÉTAPE 9] Recherche des utilisateurs orphelins...';

    SET @SQL = N'SELECT dp.name
                 FROM ' + QUOTENAME(@DatabaseName) + N'.sys.database_principals AS dp
                 LEFT JOIN sys.server_principals AS sp ON sp.sid = dp.sid
                 WHERE sp.sid IS NULL
                   AND dp.type = ''S''
                   AND dp.authentication_type_desc = ''INSTANCE''
                   AND dp.principal_id > 4;';
    INSERT INTO @Orphelins EXEC sp_executesql @SQL;

    IF EXISTS (SELECT 1 FROM @Orphelins)
    BEGIN
        SELECT
            UserName AS 'Utilisateur orphelin',
            'USE ' + QUOTENAME(@DatabaseName) + '; ALTER USER ' + QUOTENAME(UserName)
                + ' WITH LOGIN = ' + QUOTENAME(UserName) + ';' AS 'Correction (si le login existe)'
        FROM @Orphelins;
        PRINT '  ⚠ Utilisateurs orphelins détectés : voir la grille de résultats';
    END
    ELSE
        PRINT '  ✓ Aucun utilisateur orphelin';
    PRINT '';

    IF @RestoreLogId IS NOT NULL
    BEGIN
        BEGIN TRY
            EXEC sp_executesql
                N'UPDATE Log_Database.dbo.RestoreExecutionLog
                  SET EndTime = GETDATE(),
                      DurationSeconds = DATEDIFF(SECOND, @StartTime, GETDATE()),
                      Status = ''SUCCESS'',
                      TailLogFile = @TailLogFile
                  WHERE Id = @RestoreLogId;',
                N'@StartTime DATETIME, @TailLogFile NVARCHAR(500), @RestoreLogId INT',
                @StartTime = @StartTime, @TailLogFile = @TailLogFile, @RestoreLogId = @RestoreLogId;
        END TRY
        BEGIN CATCH
            PRINT 'Avertissement : mise à jour du log impossible - ' + ERROR_MESSAGE();
        END CATCH;
    END

    PRINT '═══════════════════════════════════════════════════════════';
    PRINT '✓ RESTAURATION RÉUSSIE! Durée : ' + CAST(DATEDIFF(SECOND, @StartTime, GETDATE()) AS NVARCHAR(10)) + ' seconde(s)';
    IF @TailLogFile IS NOT NULL
        PRINT 'Sauvegarde de fin de journal conservée : ' + @TailLogFile;
    PRINT '═══════════════════════════════════════════════════════════';

END TRY
BEGIN CATCH
    SET @ErrorNumber = ERROR_NUMBER();
    SET @ErrorMessage = ERROR_MESSAGE();

    PRINT '';
    PRINT '═══════════════════════════════════════════════════════════';
    PRINT '✗ ERREUR LORS DE LA RESTAURATION!';
    PRINT '═══════════════════════════════════════════════════════════';
    PRINT 'Étape: ' + ISNULL(@Etape, '?');
    PRINT 'Erreur: ' + ERROR_MESSAGE();
    PRINT 'Numéro d''erreur: ' + CAST(ERROR_NUMBER() AS NVARCHAR(20));
    PRINT 'Ligne: ' + CAST(ERROR_LINE() AS NVARCHAR(20));
    PRINT '';

    -- Remettre la base d'origine en service si la restauration n'a pas commencé
    BEGIN TRY
        SELECT @EtatActuel = state_desc FROM sys.databases WHERE name = @DatabaseName;

        IF @RestoreStarted = 0 AND @EtatActuel = 'RESTORING' AND @TailLogFile IS NOT NULL
        BEGIN
            RESTORE DATABASE @DatabaseName WITH RECOVERY;
            SET @EtatActuel = 'ONLINE';
            PRINT 'Base d''origine remise en ligne (après tail-log).';
        END
        ELSE IF @RestoreStarted = 0 AND @EtatActuel = 'OFFLINE' AND @EtatInitial = 'ONLINE'
        BEGIN
            SET @SQL = N'ALTER DATABASE ' + QUOTENAME(@DatabaseName) + N' SET ONLINE;';
            EXEC sp_executesql @SQL;
            SET @EtatActuel = 'ONLINE';
            PRINT 'Base d''origine remise en ligne.';
        END

        IF @EtatActuel = 'ONLINE'
        BEGIN
            SET @SQL = N'ALTER DATABASE ' + QUOTENAME(@DatabaseName) + N' SET MULTI_USER;';
            EXEC sp_executesql @SQL;
            PRINT 'Base remise en mode multi-utilisateur.';
        END
        ELSE IF @EtatActuel = 'RESTORING'
            PRINT '⚠ Base en état RESTORING : corrigez l''erreur (fichier manquant, ordre des journaux...) puis relancez, ou exécutez RESTORE DATABASE '
                + QUOTENAME(@DatabaseName) + ' WITH RECOVERY pour la mettre en ligne dans son état actuel.';
        ELSE IF @EtatActuel IS NOT NULL
            PRINT '⚠ Base en état ' + @EtatActuel + ' : corrigez l''erreur puis relancez la restauration.';
    END TRY
    BEGIN CATCH
        PRINT 'Impossible de remettre la base en service : ' + ERROR_MESSAGE();
    END CATCH;

    IF @TailLogFile IS NOT NULL
        PRINT 'Sauvegarde de fin de journal : ' + @TailLogFile;

    IF @RestoreLogId IS NOT NULL
    BEGIN
        BEGIN TRY
            EXEC sp_executesql
                N'UPDATE Log_Database.dbo.RestoreExecutionLog
                  SET EndTime = GETDATE(),
                      DurationSeconds = DATEDIFF(SECOND, @StartTime, GETDATE()),
                      Status = ''FAILED'',
                      TailLogFile = @TailLogFile,
                      FailedStep = @Etape,
                      ErrorNumber = @ErrorNumber,
                      ErrorMessage = @ErrorMessage
                  WHERE Id = @RestoreLogId;',
                N'@StartTime DATETIME, @TailLogFile NVARCHAR(500), @Etape NVARCHAR(200), @ErrorNumber INT, @ErrorMessage NVARCHAR(4000), @RestoreLogId INT',
                @StartTime = @StartTime, @TailLogFile = @TailLogFile, @Etape = @Etape,
                @ErrorNumber = @ErrorNumber, @ErrorMessage = @ErrorMessage, @RestoreLogId = @RestoreLogId;
        END TRY
        BEGIN CATCH
            PRINT 'Avertissement : mise à jour du log impossible - ' + ERROR_MESSAGE();
        END CATCH;
    END

    -- Relancer l'erreur pour que l'appelant (ex. job SQL Agent) voie l'échec
    THROW;

END CATCH

GO
