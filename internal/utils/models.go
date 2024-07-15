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

type MimeType string

const (
	MimeTypeImage MimeType = "image"
	MimeTypeVideo MimeType = "video"
	MimeTypeOther MimeType = "other"
	MimeTypeError MimeType = "error"
)

func (mt MimeType) String() string {
	return string(mt)
}
