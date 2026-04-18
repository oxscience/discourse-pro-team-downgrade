# frozen_string_literal: true

# name: discourse-pro-team-downgrade
# about: Downgrades trust level when user leaves all Pro Team groups
# version: 1.0.0
# authors: OX Science
# url: https://github.com/oxscience/discourse-pro-team-downgrade

after_initialize do
  PRO_USER_GROUP_NAME = "Pro-User"
  PRO_TEAMS_CATEGORY_ID = 16  # "Pro Teams" parent category
  DOWNGRADE_TO_TRUST_LEVEL = 1
  STAFF_GROUP_ID = 3  # "Team" group — not a customer group

  # When a user is removed from a Pro-granting group, check if they are
  # still in any other Pro-granting group. If not, downgrade their TL.
  DiscourseEvent.on(:user_removed_from_group) do |user, group|
    begin
      # Skip staff/admins — their TL is tied to their role
      next if user.staff?

      # Was the group the user left a Pro-granting group?
      sub_cat_ids = Category.where(parent_category_id: PRO_TEAMS_CATEGORY_ID).pluck(:id)
      was_pro_team = CategoryGroup.where(group_id: group.id, category_id: sub_cat_ids).exists?
      pro_user_group = Group.find_by(name: PRO_USER_GROUP_NAME)
      was_pro_user = pro_user_group && group.id == pro_user_group.id

      next unless was_pro_team || was_pro_user

      # Collect all Pro-granting group IDs (customer-facing only)
      pro_group_ids = CategoryGroup.where(category_id: sub_cat_ids).pluck(:group_id).uniq
      pro_group_ids << pro_user_group.id if pro_user_group
      pro_group_ids -= [STAFF_GROUP_ID]

      # Is the user still in at least one Pro-granting group?
      still_pro = GroupUser.where(user_id: user.id, group_id: pro_group_ids).exists?

      if !still_pro && user.trust_level > DOWNGRADE_TO_TRUST_LEVEL
        old_tl = user.trust_level
        user.change_trust_level!(DOWNGRADE_TO_TRUST_LEVEL)
        Rails.logger.info(
          "[pro-team-downgrade] #{user.username}: TL#{old_tl} -> TL#{DOWNGRADE_TO_TRUST_LEVEL} " \
            "(removed from #{group.name}, no other Pro-groups)"
        )
      end
    rescue => e
      Rails.logger.error("[pro-team-downgrade] Error for #{user&.username}: #{e.message}")
    end
  end
end
