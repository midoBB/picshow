package server

import (
	"strconv"
	"strings"

	"github.com/labstack/echo/v4"
)

func (fq *fileQuery) bindAndSetDefaults(e echo.Context) error {
	if err := e.Bind(fq); err != nil {
		return err
	}
	if fq.Page == nil {
		fq.Page = new(int)
		*fq.Page = 1
	}
	if fq.PageSize == nil {
		fq.PageSize = new(int)
		*fq.PageSize = 10
	}
	if fq.Order == nil {
		fq.Order = new(string)
		*fq.Order = "created_at"
	}
	if fq.OrderDir == nil {
		fq.OrderDir = new(string)
		*fq.OrderDir = "desc"
	}
	return nil
}

type fileQuery struct {
	Page     *int    `query:"page"`
	PageSize *int    `query:"page_size"`
	Order    *string `query:"order"`
	OrderDir *string `query:"direction"`
	Seed     *uint64 `query:"seed"`
	Type     *string `query:"type"`
}

type deleteRequest struct {
	IDs string `json:"ids"`
}

func (d deleteRequest) toIds() []uint64 {
	idList := strings.Split(d.IDs, ",")
	ids := make([]uint64, len(idList))
	for i, id := range idList {
		ids[i], _ = strconv.ParseUint(id, 10, 64)
	}
	return ids
}
