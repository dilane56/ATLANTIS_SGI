-- =====================================================
-- RESTAURATION D'UNE SAUVEGARDE FULL
-- SQL Server 2017 ou supérieur (STRING_AGG)
-- =====================================================

USE [master];
GO

-- =====================================================
-- PARAMÈTRES
-- =====================================================

DECLARE @DatabaseName NVARCHAR(128) = 'stage_management_db';
DECLARE @BackupFilePath NVARCHAR(500) = 'C:\Backups\StageManagementBackup\stage_management_db_28-07-2026_10H36M35S_FULL.bak';
--exemple 'C:\Backups\StageManagementBackup\stage_management_db_28-07-2026_10H36M35S_FULL.bak'

-- Sauvegarde de fin de journal (tail-log) avant d'écraser une base existante :
-- conserve les transactions postérieures à la dernière sauvegarde LOG.
DECLARE @TailLogBackup BIT = 1;
DECLARE @TailLogPath NVARCHAR(256) = 'C:\Backups\TailLog\';

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
DECLARE @Etape NVARCHAR(100);
DECLARE @EtatInitial NVARCHAR(60);
DECLARE @EtatActuel NVARCHAR(60);
DECLARE @RestoreStarted BIT = 0;

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

PRINT '═══════════════════════════════════════════════════════════';
PRINT 'DÉBUT DE LA RESTAURATION';
PRINT '═══════════════════════════════════════════════════════════';
PRINT 'Base: ' + @DatabaseName;
PRINT 'Fichier: ' + @BackupFilePath;
PRINT '───────────────────────────────────────────────────────────';
PRINT '';

BEGIN TRY

    -- =====================================================
    -- ÉTAPE 1: VÉRIFIER LE FICHIER DE SAUVEGARDE
    -- =====================================================

    SET @Etape = 'ÉTAPE 1 - Vérification du fichier';
    PRINT '[ÉTAPE 1] Vérification du fichier...';
    RESTORE VERIFYONLY FROM DISK = @BackupFilePath;
    PRINT '✓ Fichier valide!';
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
        PRINT 'ℹ Base n''existe pas encore, une nouvelle base sera créée';
    END
    ELSE IF @EtatInitial <> 'ONLINE'
    BEGIN
        PRINT 'ℹ Base en état ' + @EtatInitial + ', pas d''isolation nécessaire';
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

        PRINT '✓ Sauvegarde de fin de journal : ' + @TailLogFile;
    END
    ELSE
    BEGIN
        IF @TailLogBackup = 1
            PRINT '⚠ Tail-log impossible (mode SIMPLE ou aucune sauvegarde FULL) : les données depuis la dernière sauvegarde seront perdues';

        SET @SQL = N'ALTER DATABASE ' + QUOTENAME(@DatabaseName) + N' SET OFFLINE WITH ROLLBACK IMMEDIATE;';
        EXEC sp_executesql @SQL;
        PRINT '✓ Base mise hors ligne';
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
        EXEC sp_executesql N'RESTORE FILELISTONLY FROM DISK = @f;', N'@f NVARCHAR(500)', @f = @BackupFilePath;

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

        PRINT '✓ Fichiers déplacés vers : ' + ISNULL(@DataPath, '(inchangé)') + ' / ' + ISNULL(@LogPath, '(inchangé)');
        PRINT '';
    END

    -- =====================================================
    -- ÉTAPE 4: RESTAURER LA BASE DE DONNÉES
    -- =====================================================

    SET @Etape = 'ÉTAPE 4 - Restauration';
    PRINT '[ÉTAPE 4] Restauration en cours...';

    SET @RestoreStarted = 1;
    SET @SQL = N'RESTORE DATABASE ' + QUOTENAME(@DatabaseName)
             + N' FROM DISK = @f WITH REPLACE, RECOVERY, STATS = 10' + @MoveClause + N';';
    EXEC sp_executesql @SQL, N'@f NVARCHAR(500)', @f = @BackupFilePath;

    PRINT '✓ Base restaurée avec succès!';
    PRINT '';

    -- =====================================================
    -- ÉTAPE 5: REMETTRE EN MODE MULTI_USER
    -- =====================================================

    SET @Etape = 'ÉTAPE 5 - Remise en MULTI_USER';
    PRINT '[ÉTAPE 5] Remise en mode multi-utilisateur...';
    SET @SQL = N'ALTER DATABASE ' + QUOTENAME(@DatabaseName) + N' SET MULTI_USER;';
    EXEC sp_executesql @SQL;
    PRINT '✓ Base en mode multi-utilisateur';
    PRINT '';

    -- =====================================================
    -- ÉTAPE 6: CONTRÔLE D'INTÉGRITÉ
    -- =====================================================

    IF @RunCheckDB = 1
    BEGIN
        SET @Etape = 'ÉTAPE 6 - DBCC CHECKDB';
        PRINT '[ÉTAPE 6] Contrôle d''intégrité (DBCC CHECKDB)...';
        DBCC CHECKDB (@DatabaseName) WITH NO_INFOMSGS, ALL_ERRORMSGS;
        PRINT '✓ Aucune corruption détectée';
        PRINT '';
    END

    -- =====================================================
    -- ÉTAPE 7: UTILISATEURS ORPHELINS
    -- (utilisateurs SQL sans login correspondant sur ce serveur)
    -- =====================================================

    SET @Etape = 'ÉTAPE 7 - Utilisateurs orphelins';
    PRINT '[ÉTAPE 7] Recherche des utilisateurs orphelins...';

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
        PRINT '⚠ Utilisateurs orphelins détectés : voir la grille de résultats';
    END
    ELSE
        PRINT '✓ Aucun utilisateur orphelin';
    PRINT '';

    PRINT '═══════════════════════════════════════════════════════════';
    PRINT '✓ RESTAURATION RÉUSSIE! Durée : ' + CAST(DATEDIFF(SECOND, @StartTime, GETDATE()) AS NVARCHAR(10)) + ' seconde(s)';
    IF @TailLogFile IS NOT NULL
        PRINT 'Sauvegarde de fin de journal conservée : ' + @TailLogFile;
    PRINT '═══════════════════════════════════════════════════════════';

END TRY
BEGIN CATCH
    PRINT '';
    PRINT '═══════════════════════════════════════════════════════════';
    PRINT '✗ ERREUR LORS DE LA RESTAURATION!';
    PRINT '═══════════════════════════════════════════════════════════';
    PRINT 'Étape: ' + ISNULL(@Etape, '?');
    PRINT 'Erreur: ' + ERROR_MESSAGE();
    PRINT 'Numéro: ' + CAST(ERROR_NUMBER() AS NVARCHAR(10));
    PRINT 'Ligne: ' + CAST(ERROR_LINE() AS NVARCHAR(10));
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
        ELSE IF @EtatActuel IS NOT NULL
            PRINT '⚠ Base en état ' + @EtatActuel + ' : corrigez l''erreur puis relancez la restauration.';
    END TRY
    BEGIN CATCH
        PRINT 'Impossible de remettre la base en service : ' + ERROR_MESSAGE();
    END CATCH;

    IF @TailLogFile IS NOT NULL
        PRINT 'Sauvegarde de fin de journal : ' + @TailLogFile;

    -- Relancer l'erreur pour que l'appelant (ex. job SQL Agent) voie l'échec
    THROW;

END CATCH

GO
