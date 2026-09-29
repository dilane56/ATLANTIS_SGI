/********************************************************************
 Description  : Création / mise à niveau de la base Log_Database et
                des tables de journalisation des sauvegardes et
                restaurations. Script ré-exécutable sans risque.
 Ordre        : 1/3 (avant 02_usp_BackupDatabase.sql)
********************************************************************/

USE [master];
GO

--------------------------------------------------------
-- Base de journalisation
--------------------------------------------------------

IF DB_ID('Log_Database') IS NULL
BEGIN
    CREATE DATABASE [Log_Database];
    ALTER DATABASE [Log_Database] SET RECOVERY SIMPLE;
    PRINT '✓ Base Log_Database créée';
END
GO

USE [Log_Database];
GO

--------------------------------------------------------
-- Journal des sauvegardes
--------------------------------------------------------

IF OBJECT_ID('dbo.BackupExecutionLog', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.BackupExecutionLog
    (
        Id               INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_BackupExecutionLog PRIMARY KEY,
        ServerName       SYSNAME        NULL CONSTRAINT DF_BackupExecutionLog_ServerName DEFAULT (@@SERVERNAME),
        DatabaseName     SYSNAME        NOT NULL,
        BackupType       NVARCHAR(20)   NOT NULL,   -- FULL | FULL_COPY_ONLY | DIFFERENTIAL | LOG
        BackupFile       NVARCHAR(500)  NULL,
        StartTime        DATETIME       NOT NULL,
        EndTime          DATETIME       NULL,
        DurationSeconds  INT            NULL,
        Status           NVARCHAR(20)   NOT NULL,   -- RUNNING | SUCCESS | FAILED
        BackupSizeMB     DECIMAL(18,2)  NULL,
        CompressedSizeMB DECIMAL(18,2)  NULL,
        ErrorNumber      INT            NULL,
        ErrorMessage     NVARCHAR(MAX)  NULL,
        PurgeInfo        NVARCHAR(4000) NULL
    );
    PRINT '✓ Table BackupExecutionLog créée';
END
ELSE
BEGIN
    -- Table existante : ajout des colonnes manquantes
    IF COL_LENGTH('dbo.BackupExecutionLog', 'ServerName') IS NULL
        ALTER TABLE dbo.BackupExecutionLog ADD ServerName SYSNAME NULL
            CONSTRAINT DF_BackupExecutionLog_ServerName DEFAULT (@@SERVERNAME);
    IF COL_LENGTH('dbo.BackupExecutionLog', 'BackupSizeMB') IS NULL
        ALTER TABLE dbo.BackupExecutionLog ADD BackupSizeMB DECIMAL(18,2) NULL;
    IF COL_LENGTH('dbo.BackupExecutionLog', 'CompressedSizeMB') IS NULL
        ALTER TABLE dbo.BackupExecutionLog ADD CompressedSizeMB DECIMAL(18,2) NULL;
    IF COL_LENGTH('dbo.BackupExecutionLog', 'ErrorNumber') IS NULL
        ALTER TABLE dbo.BackupExecutionLog ADD ErrorNumber INT NULL;
    IF COL_LENGTH('dbo.BackupExecutionLog', 'PurgeInfo') IS NULL
        ALTER TABLE dbo.BackupExecutionLog ADD PurgeInfo NVARCHAR(4000) NULL;

    -- 'FULL_COPY_ONLY' demande au moins 20 caractères (nullabilité conservée)
    IF COLUMNPROPERTY(OBJECT_ID('dbo.BackupExecutionLog'), 'BackupType', 'Precision') < 20
    BEGIN
        DECLARE @SQL NVARCHAR(200) =
            N'ALTER TABLE dbo.BackupExecutionLog ALTER COLUMN BackupType NVARCHAR(20) '
            + CASE WHEN COLUMNPROPERTY(OBJECT_ID('dbo.BackupExecutionLog'), 'BackupType', 'AllowsNull') = 1
                   THEN N'NULL' ELSE N'NOT NULL' END + N';';
        EXEC sp_executesql @SQL;
    END

    PRINT '✓ Table BackupExecutionLog mise à niveau';
END
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes
               WHERE object_id = OBJECT_ID('dbo.BackupExecutionLog')
                 AND name = 'IX_BackupExecutionLog_Database_StartTime')
    CREATE INDEX IX_BackupExecutionLog_Database_StartTime
        ON dbo.BackupExecutionLog (DatabaseName, StartTime DESC);
GO

--------------------------------------------------------
-- Journal des restaurations
--------------------------------------------------------

IF OBJECT_ID('dbo.RestoreExecutionLog', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.RestoreExecutionLog
    (
        Id               INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_RestoreExecutionLog PRIMARY KEY,
        ServerName       SYSNAME        NULL CONSTRAINT DF_RestoreExecutionLog_ServerName DEFAULT (@@SERVERNAME),
        DatabaseName     SYSNAME        NOT NULL,
        RestoreType      NVARCHAR(20)   NOT NULL,   -- FULL | FULL+DIFF | FULL+DIFF+LOG
        BackupFiles      NVARCHAR(MAX)  NULL,
        StopAt           DATETIME       NULL,
        TailLogFile      NVARCHAR(500)  NULL,
        StartTime        DATETIME       NOT NULL,
        EndTime          DATETIME       NULL,
        DurationSeconds  INT            NULL,
        Status           NVARCHAR(20)   NOT NULL,   -- RUNNING | SUCCESS | FAILED
        FailedStep       NVARCHAR(200)  NULL,
        ErrorNumber      INT            NULL,
        ErrorMessage     NVARCHAR(MAX)  NULL
    );
    PRINT '✓ Table RestoreExecutionLog créée';
END
GO
