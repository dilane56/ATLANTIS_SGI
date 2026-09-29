-- =====================================================
-- RESTAURATION AVEC SAUVEGARDE FULL + DIFF
-- Version simplifiée (sans vérifications msdb)
-- SQL Server 2022 Enterprise
-- =====================================================

USE [master];
GO

-- =====================================================
-- DÉCLARATION DES VARIABLES
-- =====================================================

DECLARE @DatabaseName NVARCHAR(128) = 'note_management_db';
DECLARE @BackupFilePathFULL NVARCHAR(500) = 'C:\Backups\NoteBackup\Full\note_management_db_28-07-2026_13H00M01S_FULL.bak';
DECLARE @BackupFilePathDIFF NVARCHAR(500) = 'C:\Backups\NoteBackup\Diff\note_management_db_28-07-2026_13H15M01S_Diff.bak';
DECLARE @StartTime DATETIME = GETDATE();

PRINT '═══════════════════════════════════════════════════════════';
PRINT 'RESTAURATION AVEC SAUVEGARDE FULL + DIFF';
PRINT '═══════════════════════════════════════════════════════════';
PRINT '';
PRINT 'Base de données: ' + @DatabaseName;
PRINT 'Sauvegarde FULL: ' + @BackupFilePathFULL;
PRINT 'Sauvegarde DIFF: ' + @BackupFilePathDIFF;
PRINT 'Date/Heure début: ' + CONVERT(NVARCHAR(20), @StartTime, 121);
PRINT '───────────────────────────────────────────────────────────';
PRINT '';

BEGIN TRY

    -- =====================================================
    -- ÉTAPE 1: VÉRIFIER LES FICHIERS DE SAUVEGARDE
    -- =====================================================

    PRINT '[ÉTAPE 1] Vérification des fichiers de sauvegarde...';
    PRINT '';

    -- Vérifier le fichier FULL
    PRINT '  [1.1] Vérification du fichier FULL...';
    RESTORE VERIFYONLY FROM DISK = @BackupFilePathFULL;
    PRINT '  ✓ Fichier FULL valide!';
    PRINT '';

    -- Vérifier le fichier DIFF
    PRINT '  [1.2] Vérification du fichier DIFF...';
    RESTORE VERIFYONLY FROM DISK = @BackupFilePathDIFF;
    PRINT '  ✓ Fichier DIFF valide!';
    PRINT '';

    -- =====================================================
    -- ÉTAPE 2: VÉRIFIER L'EXISTENCE DE LA BASE
    -- =====================================================

    PRINT '[ÉTAPE 2] Vérification de l''existence de la base...';
    PRINT '';

    IF EXISTS (SELECT 1 FROM sys.databases WHERE name = @DatabaseName)
    BEGIN
        PRINT '  ✓ Base existante trouvée';
        PRINT '  Elle sera remplacée par la restauration';
    END
    ELSE
    BEGIN
        PRINT '  ✓ Base n''existe pas';
        PRINT '  Une nouvelle base sera créée';
    END

    PRINT '';

    -- =====================================================
    -- ÉTAPE 3: METTRE LA BASE EN MODE SINGLE_USER
    -- =====================================================

    PRINT '[ÉTAPE 3] Mise en mode mono-utilisateur...';
    PRINT '';

    IF EXISTS (SELECT 1 FROM sys.databases WHERE name = @DatabaseName)
    BEGIN
        EXEC ('ALTER DATABASE [' + @DatabaseName + '] SET SINGLE_USER WITH ROLLBACK IMMEDIATE;');
        PRINT '  ✓ Base en mode mono-utilisateur';
    END
    ELSE
    BEGIN
        PRINT '  ℹ Base n''existe pas encore, pas besoin de SINGLE_USER';
    END

    PRINT '';

    -- =====================================================
    -- ÉTAPE 4: RESTAURER LA SAUVEGARDE FULL
    -- =====================================================

    PRINT '[ÉTAPE 4] Restauration de la sauvegarde FULL...';
    PRINT '  ⏳ Cela peut prendre plusieurs minutes...';
    PRINT '';

    DECLARE @RestoreFULLSQL NVARCHAR(MAX);
    SET @RestoreFULLSQL = 'RESTORE DATABASE [' + @DatabaseName + '] 
                           FROM DISK = ''' + @BackupFilePathFULL + ''' 
                           WITH REPLACE, NORECOVERY, STATS = 10;';
    EXEC sp_executesql @RestoreFULLSQL;

    PRINT '';
    PRINT '  ✓ Sauvegarde FULL restaurée avec succès!';
    PRINT '';

    -- =====================================================
    -- ÉTAPE 5: RESTAURER LA SAUVEGARDE DIFF
    -- =====================================================

    PRINT '[ÉTAPE 5] Restauration de la sauvegarde DIFF...';
    PRINT '  ⏳ Cela peut prendre plusieurs minutes...';
    PRINT '';

    DECLARE @RestoreDIFFSQL NVARCHAR(MAX);
    SET @RestoreDIFFSQL = 'RESTORE DATABASE [' + @DatabaseName + '] 
                           FROM DISK = ''' + @BackupFilePathDIFF + ''' 
                           WITH RECOVERY, STATS = 10;';
    EXEC sp_executesql @RestoreDIFFSQL;

    PRINT '';
    PRINT '  ✓ Sauvegarde DIFF restaurée avec succès!';
    PRINT '';

    -- =====================================================
    -- ÉTAPE 6: REMETTRE EN MODE MULTI_USER
    -- =====================================================

    PRINT '[ÉTAPE 6] Remise en mode multi-utilisateur...';
    PRINT '';

    EXEC ('ALTER DATABASE [' + @DatabaseName + '] SET MULTI_USER;');

    PRINT '  ✓ Base en mode multi-utilisateur';
    PRINT '';

    -- =====================================================
    -- ÉTAPE 7: VÉRIFIER L'ÉTAT DE LA BASE
    -- =====================================================

    PRINT '[ÉTAPE 7] Vérification de l''état de la base...';
    PRINT '';

    SELECT 
        name AS 'Nom de la base',
        state_desc AS 'État',
        recovery_model_desc AS 'Modèle de récupération',
        CONVERT(NVARCHAR(20), create_date, 121) AS 'Date de création'
    FROM sys.databases
    WHERE name = @DatabaseName;

    PRINT '';
    PRINT '  ✓ Base opérationnelle!';
    PRINT '';

    -- =====================================================
    -- ÉTAPE 8: AFFICHER LES STATISTIQUES
    -- =====================================================

    PRINT '[ÉTAPE 8] Statistiques de restauration:';
    PRINT '';

    DECLARE @DureeSeconde INT = DATEDIFF(SECOND, @StartTime, GETDATE());
    DECLARE @DureeMinute INT = DATEDIFF(MINUTE, @StartTime, GETDATE());

    PRINT '  Durée totale: ' + CAST(@DureeMinute AS NVARCHAR(10)) + ' minute(s) et ' + 
          CAST(@DureeSeconde % 60 AS NVARCHAR(10)) + ' seconde(s)';
    PRINT '  Heure de fin: ' + CONVERT(NVARCHAR(20), GETDATE(), 121);

    PRINT '';

    PRINT '═══════════════════════════════════════════════════════════';
    PRINT '✓ RESTAURATION RÉUSSIE!';
    PRINT '═══════════════════════════════════════════════════════════';
    PRINT '';

END TRY
BEGIN CATCH
    PRINT '';
    PRINT '═══════════════════════════════════════════════════════════';
    PRINT '✗ ERREUR LORS DE LA RESTAURATION!';
    PRINT '═══════════════════════════════════════════════════════════';
    PRINT 'Erreur: ' + ERROR_MESSAGE();
    PRINT 'Numéro d''erreur: ' + CAST(ERROR_NUMBER() AS NVARCHAR(20));
    PRINT 'Ligne: ' + CAST(ERROR_LINE() AS NVARCHAR(20));
    PRINT '';

    -- Essayer de remettre en mode MULTI_USER
    BEGIN TRY
        PRINT 'Tentative de remise en mode multi-utilisateur...';
        EXEC ('ALTER DATABASE [' + @DatabaseName + '] SET MULTI_USER;');
        PRINT '✓ Base remise en mode multi-utilisateur.';
    END TRY
    BEGIN CATCH
        PRINT '✗ Impossible de remettre en mode multi-utilisateur.';
    END CATCH

    RAISERROR ('Restauration échouée', 16, 1);
END CATCH

GO