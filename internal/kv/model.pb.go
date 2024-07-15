// Code generated by protoc-gen-go. DO NOT EDIT.
// versions:
// 	protoc-gen-go v1.34.2
// 	protoc        v5.27.1
// source: model.proto

package kv

import (
	protoreflect "google.golang.org/protobuf/reflect/protoreflect"
	protoimpl "google.golang.org/protobuf/runtime/protoimpl"
	timestamppb "google.golang.org/protobuf/types/known/timestamppb"
	reflect "reflect"
	sync "sync"
)

const (
	// Verify that this generated code is sufficiently up-to-date.
	_ = protoimpl.EnforceVersion(20 - protoimpl.MinVersion)
	// Verify that runtime/protoimpl is sufficiently up-to-date.
	_ = protoimpl.EnforceVersion(protoimpl.MaxVersion - 20)
)

type File struct {
	state         protoimpl.MessageState
	sizeCache     protoimpl.SizeCache
	unknownFields protoimpl.UnknownFields

	Id           uint64                 `protobuf:"varint,1,opt,name=id,proto3" json:"id,omitempty"`
	Hash         string                 `protobuf:"bytes,2,opt,name=hash,proto3" json:"hash,omitempty"`
	CreatedAt    *timestamppb.Timestamp `protobuf:"bytes,3,opt,name=created_at,json=createdAt,proto3" json:"created_at,omitempty"`
	Filename     string                 `protobuf:"bytes,4,opt,name=filename,proto3" json:"filename,omitempty"`
	Size         int64                  `protobuf:"varint,5,opt,name=size,proto3" json:"size,omitempty"`
	MimeType     string                 `protobuf:"bytes,6,opt,name=mime_type,json=mimeType,proto3" json:"mime_type,omitempty"`
	LastModified int64                  `protobuf:"varint,7,opt,name=last_modified,json=lastModified,proto3" json:"last_modified,omitempty"`
	// Types that are assignable to Media:
	//
	//	*File_Image
	//	*File_Video
	Media isFile_Media `protobuf_oneof:"media"`
}

func (x *File) Reset() {
	*x = File{}
	if protoimpl.UnsafeEnabled {
		mi := &file_model_proto_msgTypes[0]
		ms := protoimpl.X.MessageStateOf(protoimpl.Pointer(x))
		ms.StoreMessageInfo(mi)
	}
}

func (x *File) String() string {
	return protoimpl.X.MessageStringOf(x)
}

func (*File) ProtoMessage() {}

func (x *File) ProtoReflect() protoreflect.Message {
	mi := &file_model_proto_msgTypes[0]
	if protoimpl.UnsafeEnabled && x != nil {
		ms := protoimpl.X.MessageStateOf(protoimpl.Pointer(x))
		if ms.LoadMessageInfo() == nil {
			ms.StoreMessageInfo(mi)
		}
		return ms
	}
	return mi.MessageOf(x)
}

// Deprecated: Use File.ProtoReflect.Descriptor instead.
func (*File) Descriptor() ([]byte, []int) {
	return file_model_proto_rawDescGZIP(), []int{0}
}

func (x *File) GetId() uint64 {
	if x != nil {
		return x.Id
	}
	return 0
}

func (x *File) GetHash() string {
	if x != nil {
		return x.Hash
	}
	return ""
}

func (x *File) GetCreatedAt() *timestamppb.Timestamp {
	if x != nil {
		return x.CreatedAt
	}
	return nil
}

func (x *File) GetFilename() string {
	if x != nil {
		return x.Filename
	}
	return ""
}

func (x *File) GetSize() int64 {
	if x != nil {
		return x.Size
	}
	return 0
}

func (x *File) GetMimeType() string {
	if x != nil {
		return x.MimeType
	}
	return ""
}

func (x *File) GetLastModified() int64 {
	if x != nil {
		return x.LastModified
	}
	return 0
}

func (m *File) GetMedia() isFile_Media {
	if m != nil {
		return m.Media
	}
	return nil
}

func (x *File) GetImage() *Image {
	if x, ok := x.GetMedia().(*File_Image); ok {
		return x.Image
	}
	return nil
}

func (x *File) GetVideo() *Video {
	if x, ok := x.GetMedia().(*File_Video); ok {
		return x.Video
	}
	return nil
}

type isFile_Media interface {
	isFile_Media()
}

type File_Image struct {
	Image *Image `protobuf:"bytes,8,opt,name=image,proto3,oneof"`
}

type File_Video struct {
	Video *Video `protobuf:"bytes,9,opt,name=video,proto3,oneof"`
}

func (*File_Image) isFile_Media() {}

func (*File_Video) isFile_Media() {}

type Image struct {
	state         protoimpl.MessageState
	sizeCache     protoimpl.SizeCache
	unknownFields protoimpl.UnknownFields

	FullMimeType    string `protobuf:"bytes,1,opt,name=full_mime_type,json=fullMimeType,proto3" json:"full_mime_type,omitempty"`
	Width           uint64 `protobuf:"varint,2,opt,name=width,proto3" json:"width,omitempty"`
	Height          uint64 `protobuf:"varint,3,opt,name=height,proto3" json:"height,omitempty"`
	ThumbnailWidth  uint64 `protobuf:"varint,4,opt,name=thumbnail_width,json=thumbnailWidth,proto3" json:"thumbnail_width,omitempty"`
	ThumbnailHeight uint64 `protobuf:"varint,5,opt,name=thumbnail_height,json=thumbnailHeight,proto3" json:"thumbnail_height,omitempty"`
	ThumbnailData   []byte `protobuf:"bytes,6,opt,name=thumbnail_data,json=thumbnailData,proto3" json:"thumbnail_data,omitempty"`
}

func (x *Image) Reset() {
	*x = Image{}
	if protoimpl.UnsafeEnabled {
		mi := &file_model_proto_msgTypes[1]
		ms := protoimpl.X.MessageStateOf(protoimpl.Pointer(x))
		ms.StoreMessageInfo(mi)
	}
}

func (x *Image) String() string {
	return protoimpl.X.MessageStringOf(x)
}

func (*Image) ProtoMessage() {}

func (x *Image) ProtoReflect() protoreflect.Message {
	mi := &file_model_proto_msgTypes[1]
	if protoimpl.UnsafeEnabled && x != nil {
		ms := protoimpl.X.MessageStateOf(protoimpl.Pointer(x))
		if ms.LoadMessageInfo() == nil {
			ms.StoreMessageInfo(mi)
		}
		return ms
	}
	return mi.MessageOf(x)
}

// Deprecated: Use Image.ProtoReflect.Descriptor instead.
func (*Image) Descriptor() ([]byte, []int) {
	return file_model_proto_rawDescGZIP(), []int{1}
}

func (x *Image) GetFullMimeType() string {
	if x != nil {
		return x.FullMimeType
	}
	return ""
}

func (x *Image) GetWidth() uint64 {
	if x != nil {
		return x.Width
	}
	return 0
}

func (x *Image) GetHeight() uint64 {
	if x != nil {
		return x.Height
	}
	return 0
}

func (x *Image) GetThumbnailWidth() uint64 {
	if x != nil {
		return x.ThumbnailWidth
	}
	return 0
}

func (x *Image) GetThumbnailHeight() uint64 {
	if x != nil {
		return x.ThumbnailHeight
	}
	return 0
}

func (x *Image) GetThumbnailData() []byte {
	if x != nil {
		return x.ThumbnailData
	}
	return nil
}

type Video struct {
	state         protoimpl.MessageState
	sizeCache     protoimpl.SizeCache
	unknownFields protoimpl.UnknownFields

	FullMimeType    string `protobuf:"bytes,1,opt,name=full_mime_type,json=fullMimeType,proto3" json:"full_mime_type,omitempty"`
	Width           uint64 `protobuf:"varint,2,opt,name=width,proto3" json:"width,omitempty"`
	Height          uint64 `protobuf:"varint,3,opt,name=height,proto3" json:"height,omitempty"`
	Length          uint64 `protobuf:"varint,4,opt,name=length,proto3" json:"length,omitempty"`
	ThumbnailWidth  uint64 `protobuf:"varint,5,opt,name=thumbnail_width,json=thumbnailWidth,proto3" json:"thumbnail_width,omitempty"`
	ThumbnailHeight uint64 `protobuf:"varint,6,opt,name=thumbnail_height,json=thumbnailHeight,proto3" json:"thumbnail_height,omitempty"`
	ThumbnailData   []byte `protobuf:"bytes,7,opt,name=thumbnail_data,json=thumbnailData,proto3" json:"thumbnail_data,omitempty"`
}

func (x *Video) Reset() {
	*x = Video{}
	if protoimpl.UnsafeEnabled {
		mi := &file_model_proto_msgTypes[2]
		ms := protoimpl.X.MessageStateOf(protoimpl.Pointer(x))
		ms.StoreMessageInfo(mi)
	}
}

func (x *Video) String() string {
	return protoimpl.X.MessageStringOf(x)
}

func (*Video) ProtoMessage() {}

func (x *Video) ProtoReflect() protoreflect.Message {
	mi := &file_model_proto_msgTypes[2]
	if protoimpl.UnsafeEnabled && x != nil {
		ms := protoimpl.X.MessageStateOf(protoimpl.Pointer(x))
		if ms.LoadMessageInfo() == nil {
			ms.StoreMessageInfo(mi)
		}
		return ms
	}
	return mi.MessageOf(x)
}

// Deprecated: Use Video.ProtoReflect.Descriptor instead.
func (*Video) Descriptor() ([]byte, []int) {
	return file_model_proto_rawDescGZIP(), []int{2}
}

func (x *Video) GetFullMimeType() string {
	if x != nil {
		return x.FullMimeType
	}
	return ""
}

func (x *Video) GetWidth() uint64 {
	if x != nil {
		return x.Width
	}
	return 0
}

func (x *Video) GetHeight() uint64 {
	if x != nil {
		return x.Height
	}
	return 0
}

func (x *Video) GetLength() uint64 {
	if x != nil {
		return x.Length
	}
	return 0
}

func (x *Video) GetThumbnailWidth() uint64 {
	if x != nil {
		return x.ThumbnailWidth
	}
	return 0
}

func (x *Video) GetThumbnailHeight() uint64 {
	if x != nil {
		return x.ThumbnailHeight
	}
	return 0
}

func (x *Video) GetThumbnailData() []byte {
	if x != nil {
		return x.ThumbnailData
	}
	return nil
}

type FileList struct {
	state         protoimpl.MessageState
	sizeCache     protoimpl.SizeCache
	unknownFields protoimpl.UnknownFields

	Ids             []uint64 `protobuf:"varint,1,rep,packed,name=ids,proto3" json:"ids,omitempty"`
	ImageFileIds    []uint64 `protobuf:"varint,2,rep,packed,name=imageFileIds,proto3" json:"imageFileIds,omitempty"`
	VideoFileIds    []uint64 `protobuf:"varint,3,rep,packed,name=videoFileIds,proto3" json:"videoFileIds,omitempty"`
	FavoriteFileIds []uint64 `protobuf:"varint,4,rep,packed,name=favoriteFileIds,proto3" json:"favoriteFileIds,omitempty"`
}

func (x *FileList) Reset() {
	*x = FileList{}
	if protoimpl.UnsafeEnabled {
		mi := &file_model_proto_msgTypes[3]
		ms := protoimpl.X.MessageStateOf(protoimpl.Pointer(x))
		ms.StoreMessageInfo(mi)
	}
}

func (x *FileList) String() string {
	return protoimpl.X.MessageStringOf(x)
}

func (*FileList) ProtoMessage() {}

func (x *FileList) ProtoReflect() protoreflect.Message {
	mi := &file_model_proto_msgTypes[3]
	if protoimpl.UnsafeEnabled && x != nil {
		ms := protoimpl.X.MessageStateOf(protoimpl.Pointer(x))
		if ms.LoadMessageInfo() == nil {
			ms.StoreMessageInfo(mi)
		}
		return ms
	}
	return mi.MessageOf(x)
}

// Deprecated: Use FileList.ProtoReflect.Descriptor instead.
func (*FileList) Descriptor() ([]byte, []int) {
	return file_model_proto_rawDescGZIP(), []int{3}
}

func (x *FileList) GetIds() []uint64 {
	if x != nil {
		return x.Ids
	}
	return nil
}

func (x *FileList) GetImageFileIds() []uint64 {
	if x != nil {
		return x.ImageFileIds
	}
	return nil
}

func (x *FileList) GetVideoFileIds() []uint64 {
	if x != nil {
		return x.VideoFileIds
	}
	return nil
}

func (x *FileList) GetFavoriteFileIds() []uint64 {
	if x != nil {
		return x.FavoriteFileIds
	}
	return nil
}

type Stats struct {
	state         protoimpl.MessageState
	sizeCache     protoimpl.SizeCache
	unknownFields protoimpl.UnknownFields

	Count         uint64 `protobuf:"varint,1,opt,name=count,proto3" json:"count,omitempty"`
	VideoCount    uint64 `protobuf:"varint,2,opt,name=video_count,json=videoCount,proto3" json:"video_count,omitempty"`
	ImageCount    uint64 `protobuf:"varint,3,opt,name=image_count,json=imageCount,proto3" json:"image_count,omitempty"`
	FavoriteCount uint64 `protobuf:"varint,4,opt,name=favorite_count,json=favoriteCount,proto3" json:"favorite_count,omitempty"`
}

func (x *Stats) Reset() {
	*x = Stats{}
	if protoimpl.UnsafeEnabled {
		mi := &file_model_proto_msgTypes[4]
		ms := protoimpl.X.MessageStateOf(protoimpl.Pointer(x))
		ms.StoreMessageInfo(mi)
	}
}

func (x *Stats) String() string {
	return protoimpl.X.MessageStringOf(x)
}

func (*Stats) ProtoMessage() {}

func (x *Stats) ProtoReflect() protoreflect.Message {
	mi := &file_model_proto_msgTypes[4]
	if protoimpl.UnsafeEnabled && x != nil {
		ms := protoimpl.X.MessageStateOf(protoimpl.Pointer(x))
		if ms.LoadMessageInfo() == nil {
			ms.StoreMessageInfo(mi)
		}
		return ms
	}
	return mi.MessageOf(x)
}

// Deprecated: Use Stats.ProtoReflect.Descriptor instead.
func (*Stats) Descriptor() ([]byte, []int) {
	return file_model_proto_rawDescGZIP(), []int{4}
}

func (x *Stats) GetCount() uint64 {
	if x != nil {
		return x.Count
	}
	return 0
}

func (x *Stats) GetVideoCount() uint64 {
	if x != nil {
		return x.VideoCount
	}
	return 0
}

func (x *Stats) GetImageCount() uint64 {
	if x != nil {
		return x.ImageCount
	}
	return 0
}

func (x *Stats) GetFavoriteCount() uint64 {
	if x != nil {
		return x.FavoriteCount
	}
	return 0
}

type Pagination struct {
	state         protoimpl.MessageState
	sizeCache     protoimpl.SizeCache
	unknownFields protoimpl.UnknownFields

	TotalRecords uint64  `protobuf:"varint,1,opt,name=total_records,json=totalRecords,proto3" json:"total_records,omitempty"`
	CurrentPage  uint64  `protobuf:"varint,2,opt,name=current_page,json=currentPage,proto3" json:"current_page,omitempty"`
	TotalPages   uint64  `protobuf:"varint,3,opt,name=total_pages,json=totalPages,proto3" json:"total_pages,omitempty"`
	NextPage     *uint64 `protobuf:"varint,4,opt,name=next_page,json=nextPage,proto3,oneof" json:"next_page,omitempty"`
	PrevPage     *uint64 `protobuf:"varint,5,opt,name=prev_page,json=prevPage,proto3,oneof" json:"prev_page,omitempty"`
}

func (x *Pagination) Reset() {
	*x = Pagination{}
	if protoimpl.UnsafeEnabled {
		mi := &file_model_proto_msgTypes[5]
		ms := protoimpl.X.MessageStateOf(protoimpl.Pointer(x))
		ms.StoreMessageInfo(mi)
	}
}

func (x *Pagination) String() string {
	return protoimpl.X.MessageStringOf(x)
}

func (*Pagination) ProtoMessage() {}

func (x *Pagination) ProtoReflect() protoreflect.Message {
	mi := &file_model_proto_msgTypes[5]
	if protoimpl.UnsafeEnabled && x != nil {
		ms := protoimpl.X.MessageStateOf(protoimpl.Pointer(x))
		if ms.LoadMessageInfo() == nil {
			ms.StoreMessageInfo(mi)
		}
		return ms
	}
	return mi.MessageOf(x)
}

// Deprecated: Use Pagination.ProtoReflect.Descriptor instead.
func (*Pagination) Descriptor() ([]byte, []int) {
	return file_model_proto_rawDescGZIP(), []int{5}
}

func (x *Pagination) GetTotalRecords() uint64 {
	if x != nil {
		return x.TotalRecords
	}
	return 0
}

func (x *Pagination) GetCurrentPage() uint64 {
	if x != nil {
		return x.CurrentPage
	}
	return 0
}

func (x *Pagination) GetTotalPages() uint64 {
	if x != nil {
		return x.TotalPages
	}
	return 0
}

func (x *Pagination) GetNextPage() uint64 {
	if x != nil && x.NextPage != nil {
		return *x.NextPage
	}
	return 0
}

func (x *Pagination) GetPrevPage() uint64 {
	if x != nil && x.PrevPage != nil {
		return *x.PrevPage
	}
	return 0
}

var File_model_proto protoreflect.FileDescriptor

var file_model_proto_rawDesc = []byte{
	0x0a, 0x0b, 0x6d, 0x6f, 0x64, 0x65, 0x6c, 0x2e, 0x70, 0x72, 0x6f, 0x74, 0x6f, 0x12, 0x02, 0x6b,
	0x76, 0x1a, 0x1f, 0x67, 0x6f, 0x6f, 0x67, 0x6c, 0x65, 0x2f, 0x70, 0x72, 0x6f, 0x74, 0x6f, 0x62,
	0x75, 0x66, 0x2f, 0x74, 0x69, 0x6d, 0x65, 0x73, 0x74, 0x61, 0x6d, 0x70, 0x2e, 0x70, 0x72, 0x6f,
	0x74, 0x6f, 0x22, 0xa6, 0x02, 0x0a, 0x04, 0x46, 0x69, 0x6c, 0x65, 0x12, 0x0e, 0x0a, 0x02, 0x69,
	0x64, 0x18, 0x01, 0x20, 0x01, 0x28, 0x04, 0x52, 0x02, 0x69, 0x64, 0x12, 0x12, 0x0a, 0x04, 0x68,
	0x61, 0x73, 0x68, 0x18, 0x02, 0x20, 0x01, 0x28, 0x09, 0x52, 0x04, 0x68, 0x61, 0x73, 0x68, 0x12,
	0x39, 0x0a, 0x0a, 0x63, 0x72, 0x65, 0x61, 0x74, 0x65, 0x64, 0x5f, 0x61, 0x74, 0x18, 0x03, 0x20,
	0x01, 0x28, 0x0b, 0x32, 0x1a, 0x2e, 0x67, 0x6f, 0x6f, 0x67, 0x6c, 0x65, 0x2e, 0x70, 0x72, 0x6f,
	0x74, 0x6f, 0x62, 0x75, 0x66, 0x2e, 0x54, 0x69, 0x6d, 0x65, 0x73, 0x74, 0x61, 0x6d, 0x70, 0x52,
	0x09, 0x63, 0x72, 0x65, 0x61, 0x74, 0x65, 0x64, 0x41, 0x74, 0x12, 0x1a, 0x0a, 0x08, 0x66, 0x69,
	0x6c, 0x65, 0x6e, 0x61, 0x6d, 0x65, 0x18, 0x04, 0x20, 0x01, 0x28, 0x09, 0x52, 0x08, 0x66, 0x69,
	0x6c, 0x65, 0x6e, 0x61, 0x6d, 0x65, 0x12, 0x12, 0x0a, 0x04, 0x73, 0x69, 0x7a, 0x65, 0x18, 0x05,
	0x20, 0x01, 0x28, 0x03, 0x52, 0x04, 0x73, 0x69, 0x7a, 0x65, 0x12, 0x1b, 0x0a, 0x09, 0x6d, 0x69,
	0x6d, 0x65, 0x5f, 0x74, 0x79, 0x70, 0x65, 0x18, 0x06, 0x20, 0x01, 0x28, 0x09, 0x52, 0x08, 0x6d,
	0x69, 0x6d, 0x65, 0x54, 0x79, 0x70, 0x65, 0x12, 0x23, 0x0a, 0x0d, 0x6c, 0x61, 0x73, 0x74, 0x5f,
	0x6d, 0x6f, 0x64, 0x69, 0x66, 0x69, 0x65, 0x64, 0x18, 0x07, 0x20, 0x01, 0x28, 0x03, 0x52, 0x0c,
	0x6c, 0x61, 0x73, 0x74, 0x4d, 0x6f, 0x64, 0x69, 0x66, 0x69, 0x65, 0x64, 0x12, 0x21, 0x0a, 0x05,
	0x69, 0x6d, 0x61, 0x67, 0x65, 0x18, 0x08, 0x20, 0x01, 0x28, 0x0b, 0x32, 0x09, 0x2e, 0x6b, 0x76,
	0x2e, 0x49, 0x6d, 0x61, 0x67, 0x65, 0x48, 0x00, 0x52, 0x05, 0x69, 0x6d, 0x61, 0x67, 0x65, 0x12,
	0x21, 0x0a, 0x05, 0x76, 0x69, 0x64, 0x65, 0x6f, 0x18, 0x09, 0x20, 0x01, 0x28, 0x0b, 0x32, 0x09,
	0x2e, 0x6b, 0x76, 0x2e, 0x56, 0x69, 0x64, 0x65, 0x6f, 0x48, 0x00, 0x52, 0x05, 0x76, 0x69, 0x64,
	0x65, 0x6f, 0x42, 0x07, 0x0a, 0x05, 0x6d, 0x65, 0x64, 0x69, 0x61, 0x22, 0xd6, 0x01, 0x0a, 0x05,
	0x49, 0x6d, 0x61, 0x67, 0x65, 0x12, 0x24, 0x0a, 0x0e, 0x66, 0x75, 0x6c, 0x6c, 0x5f, 0x6d, 0x69,
	0x6d, 0x65, 0x5f, 0x74, 0x79, 0x70, 0x65, 0x18, 0x01, 0x20, 0x01, 0x28, 0x09, 0x52, 0x0c, 0x66,
	0x75, 0x6c, 0x6c, 0x4d, 0x69, 0x6d, 0x65, 0x54, 0x79, 0x70, 0x65, 0x12, 0x14, 0x0a, 0x05, 0x77,
	0x69, 0x64, 0x74, 0x68, 0x18, 0x02, 0x20, 0x01, 0x28, 0x04, 0x52, 0x05, 0x77, 0x69, 0x64, 0x74,
	0x68, 0x12, 0x16, 0x0a, 0x06, 0x68, 0x65, 0x69, 0x67, 0x68, 0x74, 0x18, 0x03, 0x20, 0x01, 0x28,
	0x04, 0x52, 0x06, 0x68, 0x65, 0x69, 0x67, 0x68, 0x74, 0x12, 0x27, 0x0a, 0x0f, 0x74, 0x68, 0x75,
	0x6d, 0x62, 0x6e, 0x61, 0x69, 0x6c, 0x5f, 0x77, 0x69, 0x64, 0x74, 0x68, 0x18, 0x04, 0x20, 0x01,
	0x28, 0x04, 0x52, 0x0e, 0x74, 0x68, 0x75, 0x6d, 0x62, 0x6e, 0x61, 0x69, 0x6c, 0x57, 0x69, 0x64,
	0x74, 0x68, 0x12, 0x29, 0x0a, 0x10, 0x74, 0x68, 0x75, 0x6d, 0x62, 0x6e, 0x61, 0x69, 0x6c, 0x5f,
	0x68, 0x65, 0x69, 0x67, 0x68, 0x74, 0x18, 0x05, 0x20, 0x01, 0x28, 0x04, 0x52, 0x0f, 0x74, 0x68,
	0x75, 0x6d, 0x62, 0x6e, 0x61, 0x69, 0x6c, 0x48, 0x65, 0x69, 0x67, 0x68, 0x74, 0x12, 0x25, 0x0a,
	0x0e, 0x74, 0x68, 0x75, 0x6d, 0x62, 0x6e, 0x61, 0x69, 0x6c, 0x5f, 0x64, 0x61, 0x74, 0x61, 0x18,
	0x06, 0x20, 0x01, 0x28, 0x0c, 0x52, 0x0d, 0x74, 0x68, 0x75, 0x6d, 0x62, 0x6e, 0x61, 0x69, 0x6c,
	0x44, 0x61, 0x74, 0x61, 0x22, 0xee, 0x01, 0x0a, 0x05, 0x56, 0x69, 0x64, 0x65, 0x6f, 0x12, 0x24,
	0x0a, 0x0e, 0x66, 0x75, 0x6c, 0x6c, 0x5f, 0x6d, 0x69, 0x6d, 0x65, 0x5f, 0x74, 0x79, 0x70, 0x65,
	0x18, 0x01, 0x20, 0x01, 0x28, 0x09, 0x52, 0x0c, 0x66, 0x75, 0x6c, 0x6c, 0x4d, 0x69, 0x6d, 0x65,
	0x54, 0x79, 0x70, 0x65, 0x12, 0x14, 0x0a, 0x05, 0x77, 0x69, 0x64, 0x74, 0x68, 0x18, 0x02, 0x20,
	0x01, 0x28, 0x04, 0x52, 0x05, 0x77, 0x69, 0x64, 0x74, 0x68, 0x12, 0x16, 0x0a, 0x06, 0x68, 0x65,
	0x69, 0x67, 0x68, 0x74, 0x18, 0x03, 0x20, 0x01, 0x28, 0x04, 0x52, 0x06, 0x68, 0x65, 0x69, 0x67,
	0x68, 0x74, 0x12, 0x16, 0x0a, 0x06, 0x6c, 0x65, 0x6e, 0x67, 0x74, 0x68, 0x18, 0x04, 0x20, 0x01,
	0x28, 0x04, 0x52, 0x06, 0x6c, 0x65, 0x6e, 0x67, 0x74, 0x68, 0x12, 0x27, 0x0a, 0x0f, 0x74, 0x68,
	0x75, 0x6d, 0x62, 0x6e, 0x61, 0x69, 0x6c, 0x5f, 0x77, 0x69, 0x64, 0x74, 0x68, 0x18, 0x05, 0x20,
	0x01, 0x28, 0x04, 0x52, 0x0e, 0x74, 0x68, 0x75, 0x6d, 0x62, 0x6e, 0x61, 0x69, 0x6c, 0x57, 0x69,
	0x64, 0x74, 0x68, 0x12, 0x29, 0x0a, 0x10, 0x74, 0x68, 0x75, 0x6d, 0x62, 0x6e, 0x61, 0x69, 0x6c,
	0x5f, 0x68, 0x65, 0x69, 0x67, 0x68, 0x74, 0x18, 0x06, 0x20, 0x01, 0x28, 0x04, 0x52, 0x0f, 0x74,
	0x68, 0x75, 0x6d, 0x62, 0x6e, 0x61, 0x69, 0x6c, 0x48, 0x65, 0x69, 0x67, 0x68, 0x74, 0x12, 0x25,
	0x0a, 0x0e, 0x74, 0x68, 0x75, 0x6d, 0x62, 0x6e, 0x61, 0x69, 0x6c, 0x5f, 0x64, 0x61, 0x74, 0x61,
	0x18, 0x07, 0x20, 0x01, 0x28, 0x0c, 0x52, 0x0d, 0x74, 0x68, 0x75, 0x6d, 0x62, 0x6e, 0x61, 0x69,
	0x6c, 0x44, 0x61, 0x74, 0x61, 0x22, 0x8e, 0x01, 0x0a, 0x08, 0x46, 0x69, 0x6c, 0x65, 0x4c, 0x69,
	0x73, 0x74, 0x12, 0x10, 0x0a, 0x03, 0x69, 0x64, 0x73, 0x18, 0x01, 0x20, 0x03, 0x28, 0x04, 0x52,
	0x03, 0x69, 0x64, 0x73, 0x12, 0x22, 0x0a, 0x0c, 0x69, 0x6d, 0x61, 0x67, 0x65, 0x46, 0x69, 0x6c,
	0x65, 0x49, 0x64, 0x73, 0x18, 0x02, 0x20, 0x03, 0x28, 0x04, 0x52, 0x0c, 0x69, 0x6d, 0x61, 0x67,
	0x65, 0x46, 0x69, 0x6c, 0x65, 0x49, 0x64, 0x73, 0x12, 0x22, 0x0a, 0x0c, 0x76, 0x69, 0x64, 0x65,
	0x6f, 0x46, 0x69, 0x6c, 0x65, 0x49, 0x64, 0x73, 0x18, 0x03, 0x20, 0x03, 0x28, 0x04, 0x52, 0x0c,
	0x76, 0x69, 0x64, 0x65, 0x6f, 0x46, 0x69, 0x6c, 0x65, 0x49, 0x64, 0x73, 0x12, 0x28, 0x0a, 0x0f,
	0x66, 0x61, 0x76, 0x6f, 0x72, 0x69, 0x74, 0x65, 0x46, 0x69, 0x6c, 0x65, 0x49, 0x64, 0x73, 0x18,
	0x04, 0x20, 0x03, 0x28, 0x04, 0x52, 0x0f, 0x66, 0x61, 0x76, 0x6f, 0x72, 0x69, 0x74, 0x65, 0x46,
	0x69, 0x6c, 0x65, 0x49, 0x64, 0x73, 0x22, 0x86, 0x01, 0x0a, 0x05, 0x53, 0x74, 0x61, 0x74, 0x73,
	0x12, 0x14, 0x0a, 0x05, 0x63, 0x6f, 0x75, 0x6e, 0x74, 0x18, 0x01, 0x20, 0x01, 0x28, 0x04, 0x52,
	0x05, 0x63, 0x6f, 0x75, 0x6e, 0x74, 0x12, 0x1f, 0x0a, 0x0b, 0x76, 0x69, 0x64, 0x65, 0x6f, 0x5f,
	0x63, 0x6f, 0x75, 0x6e, 0x74, 0x18, 0x02, 0x20, 0x01, 0x28, 0x04, 0x52, 0x0a, 0x76, 0x69, 0x64,
	0x65, 0x6f, 0x43, 0x6f, 0x75, 0x6e, 0x74, 0x12, 0x1f, 0x0a, 0x0b, 0x69, 0x6d, 0x61, 0x67, 0x65,
	0x5f, 0x63, 0x6f, 0x75, 0x6e, 0x74, 0x18, 0x03, 0x20, 0x01, 0x28, 0x04, 0x52, 0x0a, 0x69, 0x6d,
	0x61, 0x67, 0x65, 0x43, 0x6f, 0x75, 0x6e, 0x74, 0x12, 0x25, 0x0a, 0x0e, 0x66, 0x61, 0x76, 0x6f,
	0x72, 0x69, 0x74, 0x65, 0x5f, 0x63, 0x6f, 0x75, 0x6e, 0x74, 0x18, 0x04, 0x20, 0x01, 0x28, 0x04,
	0x52, 0x0d, 0x66, 0x61, 0x76, 0x6f, 0x72, 0x69, 0x74, 0x65, 0x43, 0x6f, 0x75, 0x6e, 0x74, 0x22,
	0xd5, 0x01, 0x0a, 0x0a, 0x50, 0x61, 0x67, 0x69, 0x6e, 0x61, 0x74, 0x69, 0x6f, 0x6e, 0x12, 0x23,
	0x0a, 0x0d, 0x74, 0x6f, 0x74, 0x61, 0x6c, 0x5f, 0x72, 0x65, 0x63, 0x6f, 0x72, 0x64, 0x73, 0x18,
	0x01, 0x20, 0x01, 0x28, 0x04, 0x52, 0x0c, 0x74, 0x6f, 0x74, 0x61, 0x6c, 0x52, 0x65, 0x63, 0x6f,
	0x72, 0x64, 0x73, 0x12, 0x21, 0x0a, 0x0c, 0x63, 0x75, 0x72, 0x72, 0x65, 0x6e, 0x74, 0x5f, 0x70,
	0x61, 0x67, 0x65, 0x18, 0x02, 0x20, 0x01, 0x28, 0x04, 0x52, 0x0b, 0x63, 0x75, 0x72, 0x72, 0x65,
	0x6e, 0x74, 0x50, 0x61, 0x67, 0x65, 0x12, 0x1f, 0x0a, 0x0b, 0x74, 0x6f, 0x74, 0x61, 0x6c, 0x5f,
	0x70, 0x61, 0x67, 0x65, 0x73, 0x18, 0x03, 0x20, 0x01, 0x28, 0x04, 0x52, 0x0a, 0x74, 0x6f, 0x74,
	0x61, 0x6c, 0x50, 0x61, 0x67, 0x65, 0x73, 0x12, 0x20, 0x0a, 0x09, 0x6e, 0x65, 0x78, 0x74, 0x5f,
	0x70, 0x61, 0x67, 0x65, 0x18, 0x04, 0x20, 0x01, 0x28, 0x04, 0x48, 0x00, 0x52, 0x08, 0x6e, 0x65,
	0x78, 0x74, 0x50, 0x61, 0x67, 0x65, 0x88, 0x01, 0x01, 0x12, 0x20, 0x0a, 0x09, 0x70, 0x72, 0x65,
	0x76, 0x5f, 0x70, 0x61, 0x67, 0x65, 0x18, 0x05, 0x20, 0x01, 0x28, 0x04, 0x48, 0x01, 0x52, 0x08,
	0x70, 0x72, 0x65, 0x76, 0x50, 0x61, 0x67, 0x65, 0x88, 0x01, 0x01, 0x42, 0x0c, 0x0a, 0x0a, 0x5f,
	0x6e, 0x65, 0x78, 0x74, 0x5f, 0x70, 0x61, 0x67, 0x65, 0x42, 0x0c, 0x0a, 0x0a, 0x5f, 0x70, 0x72,
	0x65, 0x76, 0x5f, 0x70, 0x61, 0x67, 0x65, 0x42, 0x15, 0x5a, 0x13, 0x70, 0x69, 0x63, 0x73, 0x68,
	0x6f, 0x77, 0x2f, 0x69, 0x6e, 0x74, 0x65, 0x72, 0x6e, 0x61, 0x6c, 0x2f, 0x6b, 0x76, 0x62, 0x06,
	0x70, 0x72, 0x6f, 0x74, 0x6f, 0x33,
}

var (
	file_model_proto_rawDescOnce sync.Once
	file_model_proto_rawDescData = file_model_proto_rawDesc
)

func file_model_proto_rawDescGZIP() []byte {
	file_model_proto_rawDescOnce.Do(func() {
		file_model_proto_rawDescData = protoimpl.X.CompressGZIP(file_model_proto_rawDescData)
	})
	return file_model_proto_rawDescData
}

var file_model_proto_msgTypes = make([]protoimpl.MessageInfo, 6)
var file_model_proto_goTypes = []any{
	(*File)(nil),                  // 0: kv.File
	(*Image)(nil),                 // 1: kv.Image
	(*Video)(nil),                 // 2: kv.Video
	(*FileList)(nil),              // 3: kv.FileList
	(*Stats)(nil),                 // 4: kv.Stats
	(*Pagination)(nil),            // 5: kv.Pagination
	(*timestamppb.Timestamp)(nil), // 6: google.protobuf.Timestamp
}
var file_model_proto_depIdxs = []int32{
	6, // 0: kv.File.created_at:type_name -> google.protobuf.Timestamp
	1, // 1: kv.File.image:type_name -> kv.Image
	2, // 2: kv.File.video:type_name -> kv.Video
	3, // [3:3] is the sub-list for method output_type
	3, // [3:3] is the sub-list for method input_type
	3, // [3:3] is the sub-list for extension type_name
	3, // [3:3] is the sub-list for extension extendee
	0, // [0:3] is the sub-list for field type_name
}

func init() { file_model_proto_init() }
func file_model_proto_init() {
	if File_model_proto != nil {
		return
	}
	if !protoimpl.UnsafeEnabled {
		file_model_proto_msgTypes[0].Exporter = func(v any, i int) any {
			switch v := v.(*File); i {
			case 0:
				return &v.state
			case 1:
				return &v.sizeCache
			case 2:
				return &v.unknownFields
			default:
				return nil
			}
		}
		file_model_proto_msgTypes[1].Exporter = func(v any, i int) any {
			switch v := v.(*Image); i {
			case 0:
				return &v.state
			case 1:
				return &v.sizeCache
			case 2:
				return &v.unknownFields
			default:
				return nil
			}
		}
		file_model_proto_msgTypes[2].Exporter = func(v any, i int) any {
			switch v := v.(*Video); i {
			case 0:
				return &v.state
			case 1:
				return &v.sizeCache
			case 2:
				return &v.unknownFields
			default:
				return nil
			}
		}
		file_model_proto_msgTypes[3].Exporter = func(v any, i int) any {
			switch v := v.(*FileList); i {
			case 0:
				return &v.state
			case 1:
				return &v.sizeCache
			case 2:
				return &v.unknownFields
			default:
				return nil
			}
		}
		file_model_proto_msgTypes[4].Exporter = func(v any, i int) any {
			switch v := v.(*Stats); i {
			case 0:
				return &v.state
			case 1:
				return &v.sizeCache
			case 2:
				return &v.unknownFields
			default:
				return nil
			}
		}
		file_model_proto_msgTypes[5].Exporter = func(v any, i int) any {
			switch v := v.(*Pagination); i {
			case 0:
				return &v.state
			case 1:
				return &v.sizeCache
			case 2:
				return &v.unknownFields
			default:
				return nil
			}
		}
	}
	file_model_proto_msgTypes[0].OneofWrappers = []any{
		(*File_Image)(nil),
		(*File_Video)(nil),
	}
	file_model_proto_msgTypes[5].OneofWrappers = []any{}
	type x struct{}
	out := protoimpl.TypeBuilder{
		File: protoimpl.DescBuilder{
			GoPackagePath: reflect.TypeOf(x{}).PkgPath(),
			RawDescriptor: file_model_proto_rawDesc,
			NumEnums:      0,
			NumMessages:   6,
			NumExtensions: 0,
			NumServices:   0,
		},
		GoTypes:           file_model_proto_goTypes,
		DependencyIndexes: file_model_proto_depIdxs,
		MessageInfos:      file_model_proto_msgTypes,
	}.Build()
	File_model_proto = out.File
	file_model_proto_rawDesc = nil
	file_model_proto_goTypes = nil
	file_model_proto_depIdxs = nil
}
