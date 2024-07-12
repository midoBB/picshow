package utils

type OrderBy string

const (
	CreatedAt OrderBy = "created_at"
	Random    OrderBy = "random"
)

type OrderDirection string

const (
	Asc  OrderDirection = "asc"
	Desc OrderDirection = "desc"
)
