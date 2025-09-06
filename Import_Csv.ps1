#1-Load the csv file
function Get-EmployeeCsv{
    [CmdletBinding()]
    Param(
        [Parameter(Mandatory)]
        [string]$FilePath,
        [Parameter(Mandatory)]
        [string]$Delimiter,
        [Parameter(Mandatory)]
        [hashtable]$SyncFieldMap
    )

    try{
        $SyncProperties=$SyncFieldMap.GetEnumerator()
        $Properties=ForEach($Property in $SyncProperties){
            @{Name=$Property.Value;Expression=[scriptblock]::Create("`$_.$($Property.Key)")}
        }

        Import-Csv -Path $FilePath -Delimiter $Delimiter | Select-Object -Property $Properties

    } catch{
        Write-Error $_.Exception.Message
    }
}

#2-Load the employee already in AD
function Get-EmployeesFromAD{
    [CmdletBinding()]
    Param(
        [Parameter(Mandatory)]
        [hashtable]$SyncFieldMap,
        [Parameter(Mandatory)]
        [string]$Domain,
        [Parameter(Mandatory)]
        [string]$UniqueId
    )

    try{
        Get-ADUser -Filter {$UniqueId -like "*"} -Server $Domain -Properties @($SyncFieldMap.Values)
    }catch{
        Write-Error -Message $_.Exception.Message
    }
}

#3-Compare the Users(AD and CSV File)
function Compare-Users{
    [CmdletBinding()]
    Param(
        [Parameter(Mandatory)]
        [hashtable]$SyncFieldMap,
        [Parameter(Mandatory)]
        [string]$FilePath,
        [Parameter(Mandatory)]
        [string]$UniqueId,
        [Parameter(Mandatory)]
        [string]$Domain,
        [Parameter()]
        [string]$Delimiter=","
    )
    $CSVUsers=Get-EmployeeCsv -FilePath $FilePath -Delimiter $Delimiter -SyncFieldMap $SyncFieldMap
    $ADUsers=Get-EmployeesFromAD -SyncFieldMap $SyncFieldMap -UniqueId $UniqueId -Domain $Domain

    Compare-Object -ReferenceObject $ADUsers -DifferenceObject $CSVUsers -Property $UniqueId -IncludeEqual
}

#4-Get the new, synced and removed users in AD
function Get-UserSyncData{
    [CmdletBinding()]
    Param(
        [Parameter(Mandatory)]
        [hashtable]$SyncFieldMap,
        [Parameter(Mandatory)]
        [string]$FilePath,
        [Parameter(Mandatory)]
        [string]$UniqueId,
        [Parameter(Mandatory)]
        [string]$Domain,
        [Parameter()]
        [string]$Delimiter=","
    )
    try{
        $CompareData=Compare-Users -SyncFieldMap $SyncFieldMap -FilePath $FilePath -UniqueId $UniqueId -Delimiter $Delimiter -Domain $Domain
        $NewUsersID=$CompareData | where SideIndicator -eq "=>"
        $SyncedUsersID=$CompareData | where SideIndicator -eq "=="
        $RemovedUsersID=$CompareData | where SideIndicator -eq "<="

        $NewUsers=Get-EmployeeCsv -FilePath $FilePath -Delimiter $Delimiter -SyncFieldMap $SyncFieldMap | where $UniqueId -In $NewUsersID.$UniqueId
        $SyncedUsers=Get-EmployeeCsv -FilePath $FilePath -Delimiter $Delimiter -SyncFieldMap $SyncFieldMap | where $UniqueId -In $SyncedUsersID.$UniqueId
        $RemovedUsers=Get-EmployeesFromAD -SyncFieldMap $SyncFieldMap -Domain $Domain -UniqueId $UniqueId | where $UniqueId -In $RemovedUsersID.$UniqueId

        @{
            New=$NewUsers
            Synced=$SyncedUsers
            Removed=$RemovedUsers
        }
    }catch{
        Write-Error -Message $_.Exception.Message
    }
}

#Created the variable Mapping(Configuration)
$SyncFieldMap=@{
    EmployeeID="EmployeeID"
    FirstName="GivenName"
    LastName="Surname"
    Title="Title"
    Office="Company"
}

$UniqueId="EmployeeID"
$FilePath="C:\EmployeeData.txt"
$Delimiter=","
$Domain="luffy.local"

#Get the NewUsers, SyncedUsers and RemovedUsers
$UserData=Get-UserSyncData -SyncFieldMap $SyncFieldMap -FilePath $FilePath -UniqueId $UniqueId -Domain $Domain -Delimiter $Delimiter
