export interface User {
  id: string
  email?: string
  created_at?: string
}

export interface Org {
  id: string
  name: string
  owner: string
  created_at: string
}

export interface Profile {
  id: string
  org_id: string
  email?: string
  created_at: string
}

export interface Campaign {
  id: string
  org_id: string
  name: string
  sending_domain?: string
  inbox_email?: string
  status: string
  created_at: string
}

export interface Prospect {
  id: string
  org_id: string
  company?: string
  contact_name?: string
  email?: string
  website?: string
  phone?: string
  city?: string
  state?: string
  tags?: string[]
  created_at: string
}

export interface ProspectCampaign {
  id: string
  org_id: string
  prospect_id: string
  campaign_id: string
  status: 'new' | 'sent' | 'opened' | 'replied' | 'interested' | 'not_interested' | 'bounce'
  last_event_at?: string
}

export interface OutreachEvent {
  id: number
  org_id: string
  campaign_id?: string
  prospect_id?: string
  event_type: 'sent' | 'open' | 'reply' | 'bounce' | 'unsubscribe'
  payload?: Record<string, any>
  occurred_at: string
}

export interface Task {
  id: string
  org_id: string
  prospect_id?: string
  title: string
  due_at?: string
  status: string
  created_at: string
}

export interface Conversion {
  id: string
  org_id: string
  prospect_id?: string
  campaign_id?: string
  mrr_cents: number
  notes?: string
  created_at: string
}

export interface Suppression {
  id: string
  org_id: string
  email?: string
  domain?: string
  reason?: string
  created_at: string
}

export interface KpiData {
  prospects_added: number
  emails_sent: number
  open_rate: number
  reply_rate: number
  conversions: number
  mrr_won_cents: number
}

export interface CsvMappingField {
  csvColumn: string
  dbField: string
}

export interface CsvImportResult {
  total_rows: number
  inserted: number
  skipped: number
  errors: string[]
}
