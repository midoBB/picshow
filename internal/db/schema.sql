create table files
(
    id integer
    primary key autoincrement,
    created_at datetime default current_timestamp,
    hash text unique not null,
    filename text not null,
    size integer not null,
    mime_type text not null
);

create table images
(
    id integer
    primary key autoincrement,
    full_mime_type text not null,
    width integer not null,
    height integer not null,
    file_id integer not null,
    thumbnail_width integer not null,
    thumbnail_height integer not null,
    thumbnail_data blob not null,
    foreign key (file_id) references files (id) on delete cascade
);

create table videos
(
    id integer
    primary key autoincrement,
    full_mime_type text not null,
    width integer not null,
    height integer not null,
    length integer not null,
    file_id integer not null,
    thumbnail_width integer not null,
    thumbnail_height integer not null,
    thumbnail_data blob not null,
    foreign key (file_id) references files (id) on delete cascade
);

-- Index for file_id in images and videos tables
create index idx_images_file_id on images (file_id);
create index idx_videos_file_id on videos (file_id);

-- Trigger to delete associated image or video when a file is deleted
create trigger delete_associated_media
after delete on files
for each row
begin
delete from images where file_id = old.id;
delete from videos where file_id = old.id;
end;
