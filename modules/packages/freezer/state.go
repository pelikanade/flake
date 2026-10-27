package main

import (
	"fmt"
	"os"
	"path/filepath"
	"time"

	"github.com/glebarez/sqlite"
	"gorm.io/gorm"
	"gorm.io/gorm/logger"
)

type Job struct {
	ID         uint64 `gorm:"primaryKey"`
	Repo       string `gorm:"index"`
	Commit     string
	Result     `gorm:"embedded"`
	StartedAt  time.Time
	FinishedAt *time.Time
}

type RepositoryState struct {
	Name       string `gorm:"primaryKey"`
	LastBuilt  string
	LastResult string
	LastError  string
	UpdatedAt  time.Time
}

func openState(directory string) (*gorm.DB, error) {
	if err := os.MkdirAll(directory, 0700); err != nil {
		return nil, err
	}
	db, err := gorm.Open(sqlite.Open(filepath.Join(directory, "freezer.sqlite")), &gorm.Config{Logger: logger.Default.LogMode(logger.Silent)})
	if err != nil {
		return nil, err
	}
	sqlDB, err := db.DB()
	if err != nil {
		return nil, err
	}
	sqlDB.SetMaxOpenConns(1)
	fail := func(err error) (*gorm.DB, error) { sqlDB.Close(); return nil, err }
	if err := db.Exec("PRAGMA journal_mode=WAL").Error; err != nil {
		return fail(err)
	}
	if err := db.AutoMigrate(&Job{}, &RepositoryState{}); err != nil {
		return fail(err)
	}
	if err := db.Model(&Job{}).Where("status = ?", "running").Updates(map[string]any{"status": "interrupted", "error": "freezer restarted mid-build", "finished_at": nil}).Error; err != nil {
		return fail(err)
	}
	if err := db.Model(&Job{}).Where("status = ?", "planned").Updates(map[string]any{"status": "interrupted", "error": "freezer restarted before this job started", "finished_at": nil}).Error; err != nil {
		return fail(err)
	}
	if err := db.Model(&RepositoryState{}).Where("last_result = ?", "running").Updates(map[string]any{"last_result": "interrupted", "last_error": "freezer restarted; commit not recorded"}).Error; err != nil {
		return fail(err)
	}
	return db, nil
}

type transcriptWriter struct {
	db *gorm.DB
	id uint64
}

func (w transcriptWriter) Write(p []byte) (int, error) {
	result := w.db.Model(&Job{}).Where("id = ?", w.id).UpdateColumn("transcript", gorm.Expr("transcript || ?", string(p)))
	if result.Error != nil {
		return 0, result.Error
	}
	if result.RowsAffected != 1 {
		return 0, fmt.Errorf("job %d disappeared while recording its transcript", w.id)
	}
	return len(p), nil
}

func pruneHistory(db *gorm.DB, repo string, keep int) error {
	newest := db.Model(&Job{}).Select("id").Where("repo = ?", repo).Order("id DESC").Limit(keep)
	return db.Where("repo = ? AND status <> ? AND id NOT IN (?)", repo, "running", newest).Delete(&Job{}).Error
}
