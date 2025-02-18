with all_chats as (
-- Получем список всех чатов пользователя 
	select 
		chats.*,
		user_chats.created_at as chat_dt
	from chats 
	inner join user_chats on user_chats.chat_id = chats.id
	where user_chats.user_id = USER_CHAT_ID_reg::UUID
	and chats.deleted_at is null
),
private_user as (
	select
		all_chats.id as chat_id,
		json_build_object(
			'id', users.id,
			'email', users.email,
			'external', users.external,
			'is_active', users.is_active,
			'is_superuser', users.is_superuser,
			'is_verified', users.is_verified
		) as user
	from all_chats
	inner join user_chats on user_chats.chat_id = all_chats.id
	inner join users on users.id = user_chats.user_id
	where all_chats.type = 'private' and user_chats.user_id != USER_CHAT_ID_reg::UUID
),
all_msg as (
-- Получаем ВСЕ сообщения в этих чатах,
-- добаляем row_number в рамках каждого чата, отсортированный в обратном порядке по дате сообщения
-- Сообщение сразу собираем в json
	select
		all_chats.id as chat_id,
		all_chats.chat_dt,
		messages.created_at as msg_dt,
		messages.id as messages_id,
		json_build_object(
			'id', messages.id,
			'parent_id', messages.parent_id,
			'user_id', messages.user_id,
			'chat_id', messages.chat_id,
			'type', messages.type,
			'external', messages.external,
			'created_at', messages.created_at
		) as msg,
		row_number() over (PARTITION by messages.chat_id order by messages.created_at desc) as rn
	from all_chats
	left join messages on messages.chat_id = all_chats.id
	where messages.deleted_at is null
),
last_msg as (
-- отфильтровываем только последние сообщения
-- либо вообще без сообщений
	select
		all_msg.chat_id,
		case
			when all_msg.messages_id is null then null
			else all_msg.msg
		end as msg,
		coalesce(msg_dt, chat_dt) as dt
	from all_msg
	where all_msg.rn = 1 or msg_dt is null
),
all_chats_msg as (
-- джоиним полученные json-сообщения к чатам
	select
		all_chats.id,
		all_chats.parent_id,
		all_chats.type,
		all_chats.external,
		last_msg.dt as date,
		last_msg.msg as message
	from all_chats
	inner join last_msg on last_msg.chat_id = all_chats.id
),
inner_chats as (
-- Получаем список вложенных чатов, чьи родители так же попали в выборку
	select child.*
	from all_chats_msg as parent
	inner join all_chats_msg as child on child.parent_id = parent.id
),
top_chats as (
-- Получаем только родительские чаты
	select
		all_chats_msg.*,
		(
			select json_agg(json_build_object(
				'id', inner_chats.id,
				'parent_id', inner_chats.parent_id,
				'type', inner_chats.type,
				'external', inner_chats.external,
				'date', inner_chats.date,
				'message', inner_chats.message
			))
			from inner_chats
			where inner_chats.parent_id = all_chats_msg.id
		)	as children,
		private_user.user
	from all_chats_msg
	left join private_user on private_user.chat_id = all_chats_msg.id
	where parent_id is null
	and (all_chats_msg.type <> 'private' or (all_chats_msg.type = 'private' and all_chats_msg.message is not null))
	union all
-- Обьединяем с вложденными чатами, но чьи родители не попали в выборку
	select
		all_chats_msg.*,
		null as children,
		null as user
	from all_chats_msg
	left join inner_chats on inner_chats.id = all_chats_msg.id
	where all_chats_msg.parent_id is not null 
	and inner_chats.id is null
)
select *
from top_chats